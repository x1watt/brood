#!/bin/bash
# launch-web.sh
#
# Builds the browser version (engine to WebAssembly, then Flutter for the
# web, see tool/build_web.sh), starts the home server (tool/brood_server.dart)
# on port 9191 and opens the page in the default browser. Whatever was
# listening on that port is stopped first. Ctrl+C stops the server.
#
# The server serves the page, your game files (from BROOD_DATA, default
# ~/box/media/games/BROOD, so no browser asks for the game folder) and
# multiplayer. It listens on your network: anyone at home can open
# http://<this computer's address>:9191/ (printed below) and join a game.
#
#   ./launch-web.sh
#   PORT=9000 ./launch-web.sh    another port

set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-9191}"
url="http://127.0.0.1:$PORT/"

tool/build_web.sh

# Free the port: stop whatever listens on it.
pids="$(lsof -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [ -z "$pids" ] && command -v fuser >/dev/null; then
	pids="$(fuser "$PORT/tcp" 2>/dev/null || true)"
fi
if [ -n "$pids" ]; then
	echo "Stopping what was listening on port $PORT (pid $(echo $pids))"
	kill $pids 2>/dev/null || true
	for _ in $(seq 1 20); do
		lsof -t -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
		sleep 0.25
	done
	kill -9 $(lsof -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null) 2>/dev/null || true
fi

dart tool/brood_server.dart --port "$PORT" --web build/web &
server=$!
trap 'kill $server 2>/dev/null' EXIT INT TERM

# Open the page once the server answers.
for _ in $(seq 1 40); do
	curl -s -o /dev/null "$url" && break
	sleep 0.25
done
if command -v xdg-open >/dev/null; then
	xdg-open "$url" >/dev/null 2>&1 || echo "Open $url in a browser."
else
	echo "Open $url in a browser."
fi
wait $server
