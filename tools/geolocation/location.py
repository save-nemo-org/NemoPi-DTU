import json
import requests

def get_location_from_cell_info(cell_info_list, api_key):
    """
    Get the geolocation from cell information using Google Geolocation API.

    :param cell_info_list: List of dictionaries containing cell information.
                           Each dictionary should have the following keys:
                           - 'cellId': int
                           - 'locationAreaCode': int
                           - 'mobileCountryCode': int
                           - 'mobileNetworkCode': int
    :param api_key: Your Google API key as a string.
    :return: A dictionary with latitude and longitude if successful, or None if failed.
    """
    url = "https://www.googleapis.com/geolocation/v1/geolocate?key=" + api_key

    data = {
        "cellTowers": cell_info_list
    }

    try:
        response = requests.post(url, json=data)
        response.raise_for_status()
        location = response.json().get('location')
        if location:
            return {
                'latitude': location['lat'],
                'longitude': location['lng']
            }
        else:
            print("Location not found.")
            return None
    except requests.exceptions.RequestException as e:
        print(f"Error occurred: {e}")
        return None

if __name__ == "__main__":
    # Fill in the cell information based on the provided data
    cell_info_list = [
        {
            'cellId': xxxx,
            'locationAreaCode': xxxx,
            'mobileCountryCode': xxx,
            'mobileNetworkCode': xxxx
        },
    ]

    api_key = ""

    location = get_location_from_cell_info(cell_info_list, api_key)
    if location:
        print(f"Latitude: {location['latitude']}, Longitude: {location['longitude']}")
    else:
        print("Failed to get location.")
