import http.server
import socketserver

# Define the handler to use http.server's SimpleHTTPRequestHandler
Handler = http.server.SimpleHTTPRequestHandler

# Define the port on which to serve
PORT = 8000

# Create the socket server
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"Serving HTTP on port {PORT}")
    
    # Serve forever
    httpd.serve_forever()