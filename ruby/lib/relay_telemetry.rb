# frozen_string_literal: true

# Elko Relay telemetry client — Ruby 2.7+, stdlib only.
#
#   t = RelayTelemetry.from_env       # RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1
#   t.counter("orders.placed", 1, region: "eu")
#   t.gauge("queue.depth", 42)
#   t.timer("db.query_ms", table: "orders") { run_query }
#   t.log(:error, "checkout failed")
#   t.close                            # also flushed automatically at_exit
#
# Non-blocking: calls push to a bounded queue; a background thread POSTs gzip'd
# batches to /ingest/v1/batch with retry + backoff.
require "json"
require "net/http"
require "uri"
require "zlib"
require "stringio"
require "socket"
require "time"

class RelayTelemetry
  attr_reader :sent, :dropped

  def self.from_env(env = ENV)
    on = %w[1 true yes on].include?(env["RELAY_TELEM_ENABLED"].to_s.strip.downcase)
    new(url: env["RELAY_URL"], app_key: env["RELAY_APP_KEY"], enabled: on,
        host: env["RELAY_TELEM_HOST"], service: env["RELAY_TELEM_SERVICE"],
        env: env["RELAY_TELEM_ENV"], version: env["RELAY_TELEM_VERSION"])
  end

  def initialize(url: nil, app_key: nil, enabled: false, host: nil, service: nil, env: nil,
                 version: nil, max_queue: 10_000, flush_every: 2.0, flush_at: 500, retries: 4,
                 timeout: 5, on_error: nil)
    @url = url.to_s.sub(%r{/+\z}, "")
    @app_key = app_key.to_s
    @enabled = enabled
    @resource = { service: service, env: env, version: version,
                  host: (host.to_s.empty? ? Socket.gethostname : host) }.reject { |_, v| v.to_s.empty? }
    @max_queue, @flush_every, @flush_at, @retries, @timeout, @on_error =
      max_queue, flush_every, flush_at, retries, timeout, on_error
    @q = []
    @m = Mutex.new
    @cv = ConditionVariable.new
    @closed = false
    @sent = 0
    @dropped = 0
    return unless active?

    @thread = Thread.new { loop_flush }
    @thread.report_on_exception = false
    at_exit { close }
  end

  def active?
    @enabled && !@url.empty? && !@app_key.empty?
  end

  def counter(name, delta = 1, **tags)   = push({ kind: "metric", type: "counter", name: name, value: delta }, tags)
  def gauge(name, value, **tags)         = push({ kind: "metric", type: "gauge", name: name, value: value }, tags)
  def histogram(name, value, unit = "", **tags) = push({ kind: "metric", type: "histogram", name: name, value: value, unit: unit }, tags)
  def log(level, msg, **tags)            = push({ kind: "log", level: level.to_s, msg: msg }, tags)
  def event(name, msg = "", **tags)      = push({ kind: "event", name: name, msg: msg }, tags)
  def heartbeat                          = push({ kind: "hb" }, {})

  def span(name, trace_id:, span_id:, ms:, failed: false, parent_id: nil, **tags)
    e = { kind: "span", name: name, value: ms, unit: "ms", trace_id: trace_id, span_id: span_id,
          status: failed ? "error" : "ok" }
    e[:parent_id] = parent_id if parent_id
    push(e, tags)
  end

  # Times the block, records elapsed ms as a histogram, returns the block's value.
  def timer(name, **tags)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    histogram(name, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0, "ms", **tags)
  end

  def flush
    return unless active?

    loop do
      batch = @m.synchronize { @q.shift(1000) }
      break if batch.empty?

      if post(batch) then @m.synchronize { @sent += batch.size }
      else @m.synchronize { @dropped += batch.size }
      end
    end
  end

  def close
    return if @closed

    @closed = true
    @m.synchronize { @cv.signal }
    @thread&.join(@timeout * (@retries + 2)) unless Thread.current == @thread
    flush
  end

  private

  def push(e, tags)
    return unless active? && !@closed

    e[:tags] = tags.transform_keys(&:to_s).transform_values(&:to_s) unless tags.empty?
    e[:ts] = Time.now.utc.iso8601(3)
    @m.synchronize do
      if @q.size >= @max_queue
        @q.shift
        @dropped += 1
      end
      @q << e
      @cv.signal if @q.size >= @flush_at
    end
    nil
  end

  def loop_flush
    until @closed
      @m.synchronize { @cv.wait(@m, @flush_every) }
      flush
    end
  end

  def post(batch)
    sio = StringIO.new
    gz = Zlib::GzipWriter.new(sio)
    gz.write(JSON.generate({ resource: @resource, events: batch }))
    gz.close
    body = sio.string
    uri = URI(@url + "/ingest/v1/batch")
    delay = 0.3
    (@retries + 1).times do |attempt|
      wait = delay
      begin
        req = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{@app_key}",
                                       "Content-Type" => "application/json", "Content-Encoding" => "gzip")
        req.body = body
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                  open_timeout: @timeout, read_timeout: @timeout) { |h| h.request(req) }
        code = res.code.to_i
        return true if [200, 202].include?(code)
        return false if code >= 400 && code < 500 && code != 429 # retrying cannot help

        ra = res["Retry-After"].to_s
        wait = ra.to_f if ra =~ /\A\d+\z/ && ra.to_i.positive?
      rescue StandardError => e
        @on_error&.call(e) if attempt == @retries
      end
      if attempt < @retries
        sleep(wait + rand * wait * 0.5)
        delay = [delay * 2, 10.0].min
      end
    end
    false
  end
end
