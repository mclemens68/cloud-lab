import os
import urllib.request
import urllib.error

def lambda_handler(event, context):
    target_ip = os.getenv('TARGET_IP')
    target_port = os.getenv('TARGET_PORT')
    url = f"http://{target_ip}:{target_port}"
    
    try:
        with urllib.request.urlopen(url) as response:
            status_code = response.getcode()
            response_body = response.read().decode('utf-8')
            
        return {
            'statusCode': status_code,
            'body': response_body
        }
        
    except urllib.error.HTTPError as e:
        # Handle HTTP errors (4xx, 5xx)
        return {
            'statusCode': e.code,
            'body': e.reason
        }
        
    except urllib.error.URLError as e:
        # Handle other errors (like connection errors)
        return {
            'statusCode': 500,
            'body': str(e)
        }
