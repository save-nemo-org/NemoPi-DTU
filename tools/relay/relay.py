import socket
import threading

# Define the UDP server addresses and ports for both connections
UDP_SERVER_1_IP = '0.0.0.0'
UDP_SERVER_1_PORT = 7777
UDP_SERVER_2_IP = '0.0.0.0'
UDP_SERVER_2_PORT = 6000

# Create the UDP server sockets
udp_server_socket_1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_server_socket_1.bind((UDP_SERVER_1_IP, UDP_SERVER_1_PORT))

udp_server_socket_2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_server_socket_2.bind((UDP_SERVER_2_IP, UDP_SERVER_2_PORT))

# Global variables to store the UDP client addresses
udp_client_address_1 = None
udp_client_address_2 = None
# Locks to ensure thread-safe access to udp_client_address
udp_client_address_lock_1 = threading.Lock()
udp_client_address_lock_2 = threading.Lock()

# Function to handle communication from UDP 1 to UDP 2
def udp1_to_udp2():
    global udp_client_address_1
    while True:
        try:
            data, addr = udp_server_socket_1.recvfrom(1024)
            print("UDP 1 received:", data)
            with udp_client_address_lock_1:
                udp_client_address_1 = addr
            with udp_client_address_lock_2:
                if udp_client_address_2:
                    udp_server_socket_2.sendto(data, udp_client_address_2)
        except Exception as e:
            print(f"UDP 1 to UDP 2 forwarding error: {e}")
            break

# Function to handle communication from UDP 2 to UDP 1
def udp2_to_udp1():
    global udp_client_address_2
    while True:
        try:
            data, addr = udp_server_socket_2.recvfrom(1024)
            print("UDP 2 received:", data)
            with udp_client_address_lock_2:
                udp_client_address_2 = addr
            with udp_client_address_lock_1:
                if udp_client_address_1:
                    udp_server_socket_1.sendto(data, udp_client_address_1)
        except Exception as e:
            print(f"UDP 2 to UDP 1 forwarding error: {e}")
            break

def main():
    print(f"UDP server 1 listening on {UDP_SERVER_1_IP}:{UDP_SERVER_1_PORT}")
    print(f"UDP server 2 listening on {UDP_SERVER_2_IP}:{UDP_SERVER_2_PORT}")

    # Start threads to handle bidirectional forwarding
    threading.Thread(target=udp1_to_udp2).start()
    threading.Thread(target=udp2_to_udp1).start()

if __name__ == "__main__":
    main()
