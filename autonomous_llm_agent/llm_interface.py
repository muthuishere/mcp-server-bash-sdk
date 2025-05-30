# autonomous_llm_agent/llm_interface.py
import os
import asyncio
import openai # Uses openai.AsyncOpenAI
from dotenv import load_dotenv
import requests # Keep for potential future use
import typing # For type hinting AsyncGenerator

# Import configuration from the config file
from config import NIM_API_BASE_URL, DEFAULT_TEMPERATURE, DEFAULT_MAX_TOKENS, MAX_CONCURRENT_API_CALLS

# Load environment variables from .env file
load_dotenv()

# Retrieve the API key
NVIDIA_API_KEY = os.getenv("NVIDIA_API_KEY")

# Global OpenAI client instance and API Semaphore
nim_client = None
api_semaphore = None

if NVIDIA_API_KEY:
    nim_client = openai.AsyncOpenAI(
        base_url=NIM_API_BASE_URL,
        api_key=NVIDIA_API_KEY,
    )
    # Initialize semaphore only if MAX_CONCURRENT_API_CALLS is available and valid
    if 'MAX_CONCURRENT_API_CALLS' in globals() and MAX_CONCURRENT_API_CALLS is not None:
        try:
            val = int(MAX_CONCURRENT_API_CALLS)
            if val <= 0:
                print(f"Warning: MAX_CONCURRENT_API_CALLS in config ('{MAX_CONCURRENT_API_CALLS}') must be a positive integer. Defaulting semaphore to 1.")
                val = 1
            api_semaphore = asyncio.Semaphore(val)
            print(f"API Semaphore initialized with {val} concurrent calls.")
        except (ValueError, TypeError):
            print(f"Warning: MAX_CONCURRENT_API_CALLS in config ('{MAX_CONCURRENT_API_CALLS}') is not a valid integer. Defaulting semaphore to 1.")
            api_semaphore = asyncio.Semaphore(1)
            print("API Semaphore initialized with 1 concurrent call due to config error.")
    else: 
        print("Warning: MAX_CONCURRENT_API_CALLS not found or is None in config. Defaulting semaphore to 1.")
        api_semaphore = asyncio.Semaphore(1)
        print("API Semaphore initialized with 1 concurrent call.")

else:
    print("Error: NVIDIA_API_KEY not found in environment variables. NIM client and semaphore not initialized.")
    # nim_client and api_semaphore remain None

async def call_llm( 
    model_name: str,
    messages: list,
    temperature: float = None,
    max_tokens: int = None,
    stream: bool = False
) -> typing.Union[str, typing.AsyncGenerator[str, None], None]:
    """
    Calls the specified LLM model using the NVIDIA NIM API asynchronously.

    Args:
        model_name (str): The name/ID of the model to use.
        messages (list): A list of message objects.
        temperature (float, optional): Sampling temperature. Defaults to DEFAULT_TEMPERATURE.
        max_tokens (int, optional): Max tokens to generate. Defaults to DEFAULT_MAX_TOKENS.
        stream (bool, optional): If True, returns an async generator yielding content chunks.
                                 If False, returns a single string with the full response.

    Returns:
        str | None: Full response content if stream=False.
        typing.AsyncGenerator[str, None] | None: An async generator of content chunks if stream=True.
                                                 Returns None if a critical error occurs (e.g. client not init).
    """
    if not nim_client:
        print("Error: NIM client not initialized. NVIDIA_API_KEY might be missing.")
        return None
    if not api_semaphore:
        # This case should ideally not be reached if nim_client is available,
        # as semaphore initialization is tied to nim_client's successful setup.
        # However, as a safeguard:
        print("Error: API semaphore not initialized. This indicates an issue during setup.")
        return None

    current_temp = temperature if temperature is not None else DEFAULT_TEMPERATURE
    current_max_tokens = max_tokens if max_tokens is not None else DEFAULT_MAX_TOKENS

    async def _stream_generator() -> typing.AsyncGenerator[str, None]:
        # print(f"Streaming task for model {model_name} waiting for semaphore...") # Debug
        async with api_semaphore:
            # print(f"Streaming task for model {model_name} acquired semaphore.") # Debug
            try:
                completion_stream = await nim_client.chat.completions.create(
                    model=model_name,
                    messages=messages,
                    temperature=current_temp,
                    max_tokens=current_max_tokens,
                    stream=True
                )
                async for chunk in completion_stream:
                    if chunk.choices and chunk.choices[0].delta and chunk.choices[0].delta.content:
                        yield chunk.choices[0].delta.content
            except openai.APIError as e:
                print(f"NVIDIA NIM API Error during stream for model {model_name}: {e}")
                # Consumer of the generator will see the stream end prematurely.
                # Consider yielding a special error token or raising a custom exception if needed.
            except Exception as e:
                print(f"An unexpected error occurred during stream processing for model {model_name}: {e}")
            # finally:
                # print(f"Streaming task for model {model_name} releasing semaphore.") # Debug

    if stream:
        return _stream_generator() # Return the async generator object

    else: # Non-streaming logic
        full_content = None
        # print(f"Non-streaming task for model {model_name} waiting for semaphore...") # Debug
        async with api_semaphore:
            # print(f"Non-streaming task for model {model_name} acquired semaphore.") # Debug
            try:
                completion = await nim_client.chat.completions.create(
                    model=model_name,
                    messages=messages,
                    temperature=current_temp,
                    max_tokens=current_max_tokens,
                    stream=False
                )
                if completion.choices and completion.choices[0].message and completion.choices[0].message.content:
                    full_content = completion.choices[0].message.content
                else:
                    print(f"Error: No response content found (non-streaming) for model {model_name}.")
            except openai.APIConnectionError as e:
                print(f"Error connecting to NVIDIA NIM API (non-streaming) for model {model_name}: {e}")
            except openai.AuthenticationError as e:
                print(f"Authentication error with NVIDIA NIM API (non-streaming) for model {model_name}: {e}")
            except openai.RateLimitError as e:
                print(f"Rate limit exceeded for NVIDIA NIM API (non-streaming) for model {model_name}: {e}")
            except openai.APIError as e:
                print(f"NVIDIA NIM API returned an API Error (non-streaming) for model {model_name}: {e}")
            except Exception as e:
                print(f"An unexpected error occurred in call_llm (non-streaming) for model {model_name}: {e}")
            # finally:
                # print(f"Non-streaming task for model {model_name} releasing semaphore.") # Debug
        return full_content


async def main_test():
    print("Testing llm_interface.py (async with advanced streaming)...")
    if not NVIDIA_API_KEY or not nim_client or not api_semaphore:
        print("NVIDIA_API_KEY not set, or client/semaphore not initialized. Exiting test.")
        return

    print(f"Using API Base URL: {NIM_API_BASE_URL}")
    # Access semaphore's current value if needed, or its configured limit
    # For asyncio.Semaphore, _value shows current free slots, initial value is its capacity.
    # It's tricky to get MAX_CONCURRENT_API_CALLS directly if it was invalid and defaulted.
    # We can infer from the print statement during semaphore init or by trying to access it.
    # Let's assume it was initialized correctly based on config for this print.
    print(f"Configured MAX_CONCURRENT_API_CALLS: {MAX_CONCURRENT_API_CALLS}")


    test_model = os.getenv("NIM_TEST_MODEL_ID", "mistralai/mistral-7b-instruct-v0.2") 
    print(f"Attempting to call model: {test_model}")

    test_messages = [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Tell me a short story about a curious robot who discovers a hidden garden."}
    ]
    
    print("\n--- Testing Non-Streaming Call (async) ---")
    response_content = await call_llm(test_model, test_messages, stream=False)
    if response_content:
        print("Response (Non-Streaming):", response_content[:150] + "..." if response_content and len(response_content) > 150 else response_content)
    else:
        print("Failed to get non-streaming response.")

    print("\n--- Testing Advanced Streaming Call (async generator) ---")
    stream_gen_result = call_llm(test_model, test_messages, stream=True) 
    
    if stream_gen_result: # This will be the async generator object
        print("Streaming response (chunk by chunk):")
        full_streamed_text = ""
        try:
            # The generator itself needs to be awaited if it's produced by an async def that returns it directly
            # However, call_llm returns _stream_generator(), which is an async generator function's result.
            # So we directly iterate over it.
            async for content_chunk in stream_gen_result: 
                if content_chunk:
                    print(content_chunk, end="", flush=True)
                    full_streamed_text += content_chunk
            print("\n--- End of stream ---")
            if not full_streamed_text:
                 print("No content received from stream or stream failed early.")
            # else:
            #     print(f"Full streamed content (collected): {full_streamed_text[:150]}...")
        except Exception as e:
            print(f"\nError consuming stream: {e}")
    else:
        print("Failed to get stream generator (call_llm returned None).")
    
    print("\n--- Testing Semaphore with Concurrent Calls (Non-Streaming) ---")
    num_concurrent_tests = 5 
    print(f"Launching {num_concurrent_tests} concurrent calls (MAX_CONCURRENT_API_CALLS={MAX_CONCURRENT_API_CALLS})...")
    
    async def single_test_call(call_num):
        # print(f"Test call {call_num} attempting to acquire semaphore...") # Debug
        short_test_messages = [{"role": "user", "content": f"Hello from call {call_num}. Respond with 'Call {call_num} received.' and nothing more."}]
        response = await call_llm(test_model, short_test_messages, stream=False, temperature=0.5) # Lower temp for predictable response
        # print(f"Test call {call_num} finished. Response: {'Yes' if response else 'No'}") # Debug
        return f"Call {call_num}: {response}" if response else f"Call {call_num}: No response or error"

    tasks = [single_test_call(i+1) for i in range(num_concurrent_tests)]
    results = await asyncio.gather(*tasks, return_exceptions=True) 
    print("\nSemaphore test results (or Exception):")
    for res_or_exc in results:
        if isinstance(res_or_exc, Exception):
            print(f"  - Task resulted in an exception: {res_or_exc}")
        else:
            print(f"  - {res_or_exc}")


if __name__ == '__main__':
    asyncio.run(main_test())
