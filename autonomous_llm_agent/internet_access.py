# autonomous_llm_agent/internet_access.py
import asyncio
import httpx
import sys # For platform-specific timeout settings if needed, or general asyncio loop policy

# Define a default timeout for HTTP requests
DEFAULT_REQUEST_TIMEOUT = 10.0  # seconds

# Define a common User-Agent
COMMON_USER_AGENT = "AutonomousLLMAgent/0.1 (+http://example.com/agent-info)" # Replace with actual info if deployed

async def fetch_url_content(url: str, timeout: float = DEFAULT_REQUEST_TIMEOUT) -> str | None:
    """
    Asynchronously fetches the text content of a given URL.

    Args:
        url (str): The URL to fetch content from.
        timeout (float, optional): Timeout for the request in seconds. 
                                   Defaults to DEFAULT_REQUEST_TIMEOUT.

    Returns:
        str | None: The text content of the page if successful, otherwise None.
    """
    print(f"Attempting to fetch URL: {url}")
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            headers = {"User-Agent": COMMON_USER_AGENT}
            response = await client.get(url, headers=headers)
            
            response.raise_for_status() # Raises an HTTPStatusError for 4xx/5xx responses
            
            # Limit content size to avoid memory issues with very large pages (optional)
            # content_length = response.headers.get('Content-Length')
            # if content_length and int(content_length) > 1_000_000: # 1MB limit example
            #     print(f"Content too large: {content_length} bytes. Skipping.")
            #     return None
            
            print(f"Successfully fetched URL: {url} (Status: {response.status_code})")
            return response.text
            
    except httpx.HTTPStatusError as e:
        print(f"HTTP error occurred while fetching {url}: {e.response.status_code} - {e.response.reason_phrase}")
        return None
    except httpx.TimeoutException as e:
        print(f"Timeout occurred while fetching {url}: {e}")
        return None
    except httpx.RequestError as e: # Covers various other request errors (network, DNS, etc.)
        print(f"An error occurred during the request to {url}: {e}")
        return None
    except Exception as e:
        print(f"An unexpected error occurred while fetching {url}: {e}")
        return None

async def main_test():
    print("Testing internet_access.py...")
    
    # Test 1: A known working URL
    # Using a URL that typically returns plain text or simple HTML for easier inspection
    test_url_1 = "https://jsonplaceholder.typicode.com/todos/1" 
    print(f"\nFetching content from: {test_url_1}")
    content1 = await fetch_url_content(test_url_1)
    if content1:
        print(f"Content from {test_url_1} (excerpt):")
        print(content1[:300] + "..." if content1 and len(content1) > 300 else content1)
    else:
        print(f"Failed to fetch content from {test_url_1}.")

    # Test 2: A URL that is likely to cause an error (e.g., non-existent domain or 404)
    test_url_2 = "http://thisdomainprobablydoesnotexistabc123xyz.com/somepage"
    print(f"\nFetching content from (expected to fail): {test_url_2}")
    content2 = await fetch_url_content(test_url_2, timeout=5.0) # Shorter timeout for error test
    if content2:
        print(f"Content from {test_url_2} (UNEXPECTED):")
        print(content2[:200] + "...")
    else:
        print(f"Failed to fetch content from {test_url_2} (as expected).")

    # Test 3: A URL that might redirect
    test_url_3 = "http://httpbin.org/redirect/1" # httpbin.org redirects
    print(f"\nFetching content from (redirect test): {test_url_3}")
    content3 = await fetch_url_content(test_url_3)
    if content3:
        print(f"Content from {test_url_3} (after redirect, excerpt):")
        print(content3[:300] + "..." if content3 and len(content3) > 300 else content3)
    else:
        print(f"Failed to fetch content from {test_url_3}.")


if __name__ == '__main__':
    # Windows specific policy for asyncio if ProactorEventLoop is needed for httpx
    # This is sometimes required for httpx/httpcore on Windows with SSL.
    # If not on Windows or if default policy works, this can be removed.
    if sys.platform == "win32" and sys.version_info >= (3, 8):
         asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
            
    asyncio.run(main_test())
