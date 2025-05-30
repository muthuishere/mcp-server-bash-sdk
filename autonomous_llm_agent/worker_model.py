# autonomous_llm_agent/worker_model.py

import asyncio
import re # For parsing the FETCH_URL tag
from llm_interface import call_llm
from config import WORKER_MODEL_NAME, DEFAULT_TEMPERATURE, DEFAULT_MAX_TOKENS
from internet_access import fetch_url_content # New import

# Regex to find [FETCH_URL: <url>] and capture url and the rest of the prompt
# This regex looks for the tag anywhere in the string.
FETCH_URL_TAG_REGEX = re.compile(r"^(.*?)\[FETCH_URL:\s*(https?://[^\s\]]+)\s*\](.*)$", re.IGNORECASE | re.DOTALL)

class Worker:
    def __init__(self, model_name: str = None):
        self.model_name = model_name if model_name else WORKER_MODEL_NAME
        if not self.model_name:
            raise ValueError("Worker model name not specified and not found in config.")
        print(f"Worker initialized with model: {self.model_name}")

    async def generate_response(self, task_prompt: str, conversation_history: list = None) -> str | None:
        current_prompt_for_llm = task_prompt
        
        # Check for [FETCH_URL: <url>] tag
        match = FETCH_URL_TAG_REGEX.match(task_prompt)
        
        if match:
            print("FETCH_URL tag detected in prompt.")
            prefix_prompt = match.group(1).strip()
            url_to_fetch = match.group(2)
            suffix_prompt = match.group(3).strip()
            
            # Reconstruct the original instruction without the FETCH_URL tag
            original_instruction = (prefix_prompt + " " + suffix_prompt).strip()
            
            # If the original instruction becomes empty, it means the prompt was ONLY the tag.
            # In this case, we should define a default instruction for the LLM.
            if not original_instruction: 
                original_instruction = f"Summarize or describe the content found at the URL."
                # The URL itself will be part of the context_from_url_str below.

            print(f"Extracted URL for fetching: {url_to_fetch}")
            print(f"Original instruction part: \"{original_instruction}\"")

            fetched_content = await fetch_url_content(url_to_fetch)
            
            context_from_url_str = ""
            if fetched_content:
                # Truncate very long content to avoid excessively long prompts
                max_fetched_content_len = 4000 # Characters, adjust as needed
                if len(fetched_content) > max_fetched_content_len:
                    fetched_content_excerpt = fetched_content[:max_fetched_content_len] + "... (content truncated)"
                else:
                    fetched_content_excerpt = fetched_content
                context_from_url_str = f"--- Context from URL: {url_to_fetch} ---\n{fetched_content_excerpt}\n--- End of Context ---"
            else:
                context_from_url_str = f"--- Note: Attempted to fetch content from URL {url_to_fetch} but failed. Please inform the user if relevant. ---"

            # Augment the prompt for the LLM
            current_prompt_for_llm = (
                f"{original_instruction}\n\n"
                f"{context_from_url_str}\n\n"
                f"Based on the original instruction and the context from the URL (if available and relevant), please provide your response."
            )
            # print(f"DEBUG: Augmented prompt for LLM (after fetch attempt): \"{current_prompt_for_llm[:300]}...\"") # For debugging
        
        # Prepare messages for LLM call
        messages = []
        if conversation_history:
            messages.extend(conversation_history)
        messages.append({"role": "user", "content": current_prompt_for_llm})

        print(f"Worker ({self.model_name}) generating response for effective prompt: \"{current_prompt_for_llm[:100]}...\"")
        response_content = await call_llm(
            model_name=self.model_name,
            messages=messages,
            temperature=DEFAULT_TEMPERATURE,
            max_tokens=DEFAULT_MAX_TOKENS
        )

        if response_content:
            print(f"Worker ({self.model_name}) received response: \"{response_content[:100]}...\"")
            return response_content
        else:
            print(f"Worker ({self.model_name}) failed to get a response.")
            return None

async def test_worker_logic():
    print("Testing worker_model.py (async with internet access)...")
    worker = None
    try:
        worker = Worker()
    except ValueError as e:
        print(f"Error initializing worker: {e}")
    except Exception as e:
        print(f"An unexpected error occurred during Worker initialization: {e}")

    if not worker:
        print("Worker could not be initialized. Skipping tests.")
        return

    # Test 1: Standard prompt (no internet access)
    sample_task = "Explain the concept of a Large Language Model in three sentences."
    print(f"\n--- Test 1: Standard Task ---")
    print(f"Sending task to worker: \"{sample_task}\"")
    response = await worker.generate_response(sample_task)
    if response: print(f"Worker's Response:\n{response}")
    else: print("Worker failed to generate a response.")

    # Test 2: With conversation history (no internet access)
    print(f"\n--- Test 2: Task with History ---")
    history = [
        {"role": "user", "content": "What is the main programming language used for AI?"},
        {"role": "assistant", "content": "Python is widely regarded as the main programming language for AI..."}
    ]
    follow_up_task = "Why is Python preferred over, say, Java for these tasks?"
    print(f"Sending follow-up task to worker: \"{follow_up_task}\"")
    response_with_history = await worker.generate_response(follow_up_task, conversation_history=history)
    if response_with_history: print(f"Worker's Response (with history):\n{response_with_history}")
    else: print("Worker failed to generate response with history.")

    # Test 3: Prompt with FETCH_URL tag
    print(f"\n--- Test 3: Task with FETCH_URL ---")
    url_for_test = "https://jsonplaceholder.typicode.com/todos/1" 
    task_with_fetch = f"Please tell me the title of the to-do item found in [FETCH_URL: {url_for_test}]. What is its completed status?"
    print(f"Sending task with FETCH_URL to worker: \"{task_with_fetch}\"")
    
    response_with_fetch = await worker.generate_response(task_with_fetch)
    if response_with_fetch:
        print(f"Worker's Response (with fetched content):\n{response_with_fetch}")
    else:
        print("Worker failed to generate a response for the task with FETCH_URL.")

    # Test 4: Prompt with FETCH_URL tag for a non-existent URL
    print(f"\n--- Test 4: Task with FETCH_URL (Bad URL) ---")
    bad_url_for_test = "http://thisdomainshouldnotexistbacasdnsa.com/data.json"
    task_with_bad_fetch = f"What data did you find at [FETCH_URL: {bad_url_for_test}]? Please describe it."
    print(f"Sending task with bad FETCH_URL to worker: \"{task_with_bad_fetch}\"")

    response_with_bad_fetch = await worker.generate_response(task_with_bad_fetch)
    if response_with_bad_fetch:
        print(f"Worker's Response (with failed fetch attempt):\n{response_with_bad_fetch}")
    else:
        print("Worker failed to generate a response for the task with bad FETCH_URL.")

    # Test 5: Prompt that is ONLY the FETCH_URL tag
    print(f"\n--- Test 5: Task with ONLY FETCH_URL tag ---")
    only_fetch_task = f"[FETCH_URL: {url_for_test}]"
    print(f"Sending task with only FETCH_URL tag to worker: \"{only_fetch_task}\"")
    response_only_fetch = await worker.generate_response(only_fetch_task)
    if response_only_fetch:
        print(f"Worker's Response (only FETCH_URL):\n{response_only_fetch}")
    else:
        print("Worker failed to generate a response for the task with only FETCH_URL.")


if __name__ == '__main__':
    asyncio.run(test_worker_logic())
