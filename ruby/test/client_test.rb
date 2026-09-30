require "minitest/autorun"
require "socket"
require "json"
require "zlib"
require "stringio"
require_relative "../lib/relay_telemetry"

# tiny raw-socket mock hub (no gems)
def mock_hub(codes)
  srv = TCPServer.new("127.0.0.1", 0)
  got = { events: 0, posts: 0 }
  Thread.new do
    loop do
      s = srv.accept
      head = +""
      head << s.gets until head.end_with?("\r\n\r\n") || s.eof?
      len = head[/content-length: (\d+)/i, 1].to_i
      body = s.read(len)
      code = codes.shift || 202
      if code == 202
        got[:events] += JSON.parse(Zlib::GzipReader.new(StringIO.new(body)).read)["events"].size
        got[:posts] += 1
      end
      extra = code == 429 ? "Retry-After: 0\r\n" : ""
      s.write "HTTP/1.1 #{code} X\r\n#{extra}Content-Length: 2\r\nConnection: close\r\n\r\n{}"
      s.close
    end
  end
  [srv.addr[1], got]
end

class ClientTest < Minitest::Test
  def test_batch_and_close
    port, got = mock_hub([])
    c = RelayTelemetry.new(url: "http://127.0.0.1:#{port}", app_key: "rk_t", enabled: true, flush_every: 3600)
    300.times { c.counter("n", 1, a: "b") }
    c.timer("t") { 1 }
    c.close
    assert_equal [301, 1, 301], [got[:events], got[:posts], c.sent]
  end

  def test_retry_429_and_drop_400
    port, got = mock_hub([429])
    c = RelayTelemetry.new(url: "http://127.0.0.1:#{port}", app_key: "rk_t", enabled: true, flush_every: 3600)
    c.gauge("g", 1); c.close
    assert_equal [1, 1, 0], [got[:events], c.sent, c.dropped]
    port2, = mock_hub([400])
    d = RelayTelemetry.new(url: "http://127.0.0.1:#{port2}", app_key: "rk_t", enabled: true, flush_every: 3600)
    d.gauge("g", 1); d.close
    assert_equal [0, 1], [d.sent, d.dropped]
  end

  def test_disabled_noop_and_bound
    RelayTelemetry.new.gauge("g", 1)
    c = RelayTelemetry.new(url: "http://127.0.0.1:1", app_key: "k", enabled: true, max_queue: 3,
                           flush_every: 3600, flush_at: 10**9, retries: 0)
    10.times { c.gauge("g", 1) }
    assert_equal 7, c.dropped
  end
end
