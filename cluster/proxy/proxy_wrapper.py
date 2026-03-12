import sys
import os
# Import here so it sees the modified environment
from litellm.proxy.proxy_cli import run_server

print("env variables:")
print('http_proxy', os.environ.get('http_proxy',   None) )
print('https_proxy', os.environ.get('https_proxy', None) )
print('HTTP_PROXY', os.environ.get('HTTP_PROXY',   None) )
print('HTTPS_PROXY', os.environ.get('HTTPS_PROXY', None) )

os.environ['http_proxy'] = ''
os.environ['https_proxy'] = ''
os.environ['HTTP_PROXY'] = ''
os.environ['HTTPS_PROXY'] = ''

if __name__ == "__main__":
    # sys.argv mimics CLI arguments for the run_server function
    sys.argv = [
        "litellm", 
        "--config", "/tmp/config.yaml", 
        "--port", "4000", 
        "--host", "0.0.0.0",
        # Add the internal Zero Trust identity
        "--ssl_keyfile_path", "/app/certs/proxy.key",
        "--ssl_certfile_path", "/app/certs/proxy.crt"
    ]
    run_server()