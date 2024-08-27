import socket
import threading

# Define the TCP and UDP server addresses
TCP_SERVER_IP = '0.0.0.0'
TCP_SERVER_PORT = 7777
UDP_SERVER_IP = '0.0.0.0'
UDP_SERVER_PORT = 6000

# Create the TCP server socket
tcp_server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp_server_socket.bind((TCP_SERVER_IP, TCP_SERVER_PORT))
tcp_server_socket.listen(1)

# Create the UDP server socket
udp_server_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_server_socket.bind((UDP_SERVER_IP, UDP_SERVER_PORT))

# Global variable to store the UDP client address
udp_client_address = None
# Lock to ensure thread-safe access to udp_client_address
udp_client_address_lock = threading.Lock()

# Function to handle communication from TCP to UDP
def tcp_to_udp(client_socket):
    global udp_client_address
    while True:
        try:
            data = client_socket.recv(1024)
            print("TCP", data)
            if not data:
                break
            with udp_client_address_lock:
                if udp_client_address:
                    udp_server_socket.sendto(data, udp_client_address)
        except Exception as e:
            print(f"TCP to UDP forwarding error: {e}")
            break
    client_socket.close()

# Function to handle communication from UDP to TCP
def udp_to_tcp(client_socket):
    global udp_client_address
    while True:
        try:
            data, addr = udp_server_socket.recvfrom(1024)
            print("UDP", data)
            with udp_client_address_lock:
                udp_client_address = addr
            client_socket.sendall(data)
        except Exception as e:
            print(f"UDP to TCP forwarding error: {e}")
            break

def main():
    print(f"TCP server listening on {TCP_SERVER_IP}:{TCP_SERVER_PORT}")
    client_socket, client_address = tcp_server_socket.accept()
    print(f"TCP connection from {client_address} accepted.")

    # Start threads to handle bidirectional forwarding
    threading.Thread(target=tcp_to_udp, args=(client_socket,)).start()
    threading.Thread(target=udp_to_tcp, args=(client_socket,)).start()

if __name__ == "__main__":
    main()
