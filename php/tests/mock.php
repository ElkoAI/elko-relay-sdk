<?php
// minimal mock hub for the smoke test (php -S)
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
if ($auth !== 'Bearer rk_t') { http_response_code(401); echo '{}'; return; }
$raw = file_get_contents('php://input');
if (($_SERVER['HTTP_CONTENT_ENCODING'] ?? '') === 'gzip') { $raw = gzdecode($raw); }
$j = json_decode($raw, true);
http_response_code(is_array($j['events'] ?? null) ? 202 : 400);
echo json_encode(['ok' => true, 'accepted' => count($j['events'] ?? [])]);
