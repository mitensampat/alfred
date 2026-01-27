#!/usr/bin/env python3
"""
Simple HTTP server for Alfred web interface
Serves the static HTML and proxies API calls to the Swift backend
"""

import http.server
import socketserver
import urllib.request
import json
from urllib.parse import urlparse, parse_qs

PORT = 8080
DIRECTORY = "Sources/GUI/Resources"

class AlfredHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_GET(self):
        if self.path.startswith('/web/'):
            # Serve web files
            self.path = self.path.replace('/web/', '/')
            return super().do_GET()
        else:
            self.send_error(404, "Not found")

    def do_POST(self):
        if self.path.startswith('/api/'):
            # Handle API requests - for now just return error
            self.send_response(503)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {"error": "Swift backend not running. Use CLI instead: swift run alfred"}
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_error(404, "Not found")

print(f"Starting server on http://localhost:{PORT}")
print(f"Web interface: http://localhost:{PORT}/web/index-notion.html")
print("Note: API calls won't work - this only serves static files")
print("For full functionality, run: swift run alfred")
print()

with socketserver.TCPServer(("", PORT), AlfredHTTPRequestHandler) as httpd:
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
