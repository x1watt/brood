#!/bin/bash
# launch-web.sh
#
# Builds the browser version (engine to WebAssembly, then Flutter for the
# web, see tool/build_web.sh), serves build/web on this computer and opens
# it in the default browser. Ctrl+C stops the server.
#
#   ./launch-web.sh              port 8080 (or the next free one)
#   PORT=9000 ./launch-web.sh

set -euo pipefail
cd "$(dirname "$0")"

tool/build_web.sh

# The first free port from PORT on.
port="${PORT:-8080}"
while python3 -c "import socket,sys; s=socket.socket(); sys.exit(s.connect_ex(('127.0.0.1', $port)) != 0)" 2>/dev/null; do
	port=$((port + 1))
done
url="http://127.0.0.1:$port/"

echo "Serving build/web at $url (Ctrl+C to stop)"
python3 -m http.server "$port" --bind 127.0.0.1 -d build/web &
server=$!
trap 'kill $server 2>/dev/null' EXIT INT TERM
sleep 1
if command -v xdg-open >/dev/null; then
	xdg-open "$url" >/dev/null 2>&1 || echo "Open $url in a browser."
else
	echo "Open $url in a browser."
fi
wait $server
