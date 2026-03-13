import sys
import os
# Import here so it sees the modified environment
from litellm.proxy.proxy_cli import run_server


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