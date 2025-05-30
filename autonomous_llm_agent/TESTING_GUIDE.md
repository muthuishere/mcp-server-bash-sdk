# Autonomous LLM Agent - Testing Guide

This guide provides instructions on how to set up, run, and test the Autonomous LLM Agent.

## 1. Prerequisites

Before you can run the agent, please ensure you have the following set up:

*   **Python:** Python 3.8 or newer is recommended.
*   **Virtual Environment:** It's highly recommended to use a virtual environment to manage dependencies.
    ```bash
    # Navigate to the autonomous_llm_agent directory
    cd path/to/autonomous_llm_agent

    # Create a virtual environment (e.g., named .venv)
    python -m venv .venv

    # Activate the virtual environment
    # On macOS and Linux:
    source .venv/bin/activate
    # On Windows (Git Bash or similar):
    # source .venv/Scripts/activate
    # On Windows (Command Prompt/PowerShell):
    # .venv\Scripts\activate.bat 
    # or
    # .venv\Scripts\Activate.ps1
    ```
*   **Install Dependencies:** Once the virtual environment is active, install the required Python packages.
    ```bash
    pip install -r requirements.txt
    ```
*   **API Key Setup:** You need an NVIDIA API Key to interact with the NIM services.
    1.  Copy the template file:
        ```bash
        cp .env_template .env
        ```
    2.  Open the `.env` file in a text editor.
    3.  Replace `"YOUR_NVIDIA_API_KEY_HERE"` with your actual NVIDIA API key. Save the file.
        ```env
        # Example content of .env
        NVIDIA_API_KEY="nvapi-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" 
        ```

## 2. Critical Model Configuration

For the agent to function correctly, you **must** configure the LLM model names it will use. These are defined in `autonomous_llm_agent/config.py`.

*   Open `autonomous_llm_agent/config.py`.
*   Locate the following variables:
    *   `WORKER_MODEL_NAME`
    *   `EVALUATOR_MODEL_NAME`
*   These are initially set to placeholder values (e.g., `"nvidia/some-worker-model"`). You need to replace these placeholders with actual, valid NVIDIA NIM model IDs that are accessible with your API key and service tier.
    *   **Example Placeholder:** `WORKER_MODEL_NAME = "nvidia/some-worker-model"`
    *   **Example Actual ID (illustrative, find valid ones in NVIDIA docs):** `WORKER_MODEL_NAME = "meta/llama3-8b-instruct"` or `EVALUATOR_MODEL_NAME = "mistralai/mistral-large"`
*   Failure to set these to valid model IDs will result in errors when the agent tries to make LLM calls. Refer to the NVIDIA NIM documentation for a list of available models and their identifiers.

You can also review other settings in `config.py` like `DEFAULT_TEMPERATURE`, `DEFAULT_MAX_TOKENS`, etc., but the model names are critical for basic operation.

## 3. Running the Agent

Once prerequisites and model configurations are complete, you can run the main orchestration script:

```bash
python autonomous_llm_agent/main.py
```
(Ensure you are in the root of the repository, or adjust the path to `main.py` accordingly if you are already in the `autonomous_llm_agent` directory, then it would be `python main.py`).

## 4. Observing Concurrent Output

The `main.py` script is designed to run multiple tasks concurrently. To help you distinguish the output from each task, log messages are prefixed with a `[Task-ID]`, for example:

```
[Task-Alpha] --- Iteration 1/3 ---
[Task-Beta] --- Iteration 1/3 ---
[Task-Alpha] Worker's Response: ...
[Task-Gamma] FETCH_URL tag detected in prompt.
...
```
This interleaved output shows that the agent is working on multiple tasks simultaneously, thanks to Python's `asyncio` capabilities.

## 5. Rate Limiting & `MAX_CONCURRENT_API_CALLS`

The agent includes a mechanism to limit the number of concurrent API calls to the NVIDIA NIM service. This is important for:
*   Respecting API rate limits imposed by the provider.
*   Preventing your IP or API key from being temporarily blocked due to too many rapid requests.
*   Managing costs if API calls are billed per request.

This is controlled by:
*   `MAX_CONCURRENT_API_CALLS` in `config.py`: Sets the maximum number of simultaneous API calls allowed.
*   `api_semaphore` in `llm_interface.py`: The `asyncio.Semaphore` object that enforces this limit.

**Tuning `MAX_CONCURRENT_API_CALLS`:**

The default value for `MAX_CONCURRENT_API_CALLS` (e.g., 3) is a safe starting point. You may be able to increase this for better throughput depending on your specific API key limits and network conditions.

1.  **Start with the Default:** Ensure `MAX_CONCURRENT_API_CALLS` in `config.py` is set to its default (e.g., 3).
2.  **Run the Agent:** Execute `python autonomous_llm_agent/main.py`.
3.  **Monitor Output:** Carefully watch the console output for:
    *   `openai.RateLimitError` (often associated with HTTP 429 errors).
    *   Custom messages from `llm_interface.py` like "Rate limit exceeded for NVIDIA NIM API...".
    *   Repeated failures of API calls across multiple tasks.
4.  **No Errors? Consider Increasing:** If the agent runs smoothly with several tasks (e.g., the 4 default tasks in `main.py`) and you see no rate limit errors, you can try increasing `MAX_CONCURRENT_API_CALLS` slightly (e.g., from 3 to 4 or 5).
5.  **Retest:** Save `config.py` and run `python autonomous_llm_agent/main.py` again.
6.  **Repeat:** The goal is to find the highest value for `MAX_CONCURRENT_API_CALLS` that allows the agent to operate efficiently without hitting rate limits for your specific API key and NVIDIA NIM service plan.
7.  **Caution:**
    *   Do not set this value excessively high. This can lead to consistent API errors and could potentially get your API key or IP address temporarily throttled or blocked by the API provider.
    *   The ideal value can change based on NVIDIA's API policies, your current service tier, or even network conditions. If you start seeing rate limit errors, reduce this value.

## 6. Verifying Advanced Streaming

The `llm_interface.py` module now supports true asynchronous, generator-based streaming. This means it can yield chunks of content from the LLM as they arrive.

*   **Direct Test:** To see this in action, you can run `llm_interface.py` directly:
    ```bash
    python autonomous_llm_agent/llm_interface.py
    ```
    The test block in this script (`main_test`) includes a section "Testing Advanced Streaming Call (async generator)" which will print content chunk by chunk as it's received from the LLM.
*   **Integration in `main.py` (Conceptual):**
    Currently, the `Worker` and `Evaluator` models in `main.py` consume the full response from `call_llm` (even if `stream=True` is passed to `call_llm` by mistake, as `call_llm` internally concatenates it in that specific scenario if not consumed as a stream by the caller).
    To make the orchestrator truly handle streams (e.g., for displaying partial results faster), you would need to:
    1.  Modify `Worker.generate_response` (and potentially `Evaluator.evaluate_response`) to also be an async generator if it needs to yield chunks upwards.
    2.  Update `main.py`'s `run_orchestration` loop to `async for chunk in worker.generate_response(...)` and process these chunks.
    This is a more advanced refactoring of the main loop itself.

## 7. Verifying Internet Access

The `Worker` model can fetch content from URLs if a special tag `[FETCH_URL: <url>]` is included in the task prompt.

*   **Check `main.py` Tasks:** The `main_concurrent_runner` in `main.py` includes "Task-Gamma" with a prompt like:
    `"What are the key ingredients in a Margherita pizza? [FETCH_URL: https://en.wikipedia.org/wiki/Margherita_pizza] Please list them based on the source if possible."`
    When this task runs, observe its output. The worker's response should ideally contain information fetched from the Wikipedia page.
*   **Direct Test:** You can test the URL fetching mechanism directly by running:
    ```bash
    python autonomous_llm_agent/internet_access.py
    ```
    This script has its own tests for fetching different types of URLs.

## 8. General Debugging Tips

*   **Read Console Output:** Error messages from any module (`llm_interface`, `worker_model`, `evaluator_model`, `internet_access`, `main`) are printed to the console. These are your first clue if something goes wrong.
*   **Add Print Statements:** If you're unsure about the state of variables or the flow of logic, don't hesitate to add temporary `print()` statements in the Python code. For example:
    *   Print the full prompt being sent to an LLM.
    *   Print the raw response received from an LLM before parsing.
    *   Print dictionary contents or specific variables at different stages.
*   **Interaction Log:** The `full_interaction_log` variable in `main.py`'s `run_orchestration` function is designed to capture the sequence of user prompts, assistant responses, and evaluations for a single task. While it's not fully printed by default at the end of each task in the current version (to avoid excessive console output in concurrent runs), you could uncomment or add code to print this log for a specific task if you need to debug its detailed lifecycle:
    ```python
    # In main.py, at the end of run_orchestration, before returning:
    # import json
    # print(f"[{task_id}] Full Interaction Log:\n{json.dumps(full_interaction_log, indent=2)}")
    ```
*   **Check Model IDs:** Double-check that `WORKER_MODEL_NAME` and `EVALUATOR_MODEL_NAME` in `config.py` are correct and that these models are available to your API key. This is a common source of errors.
*   **API Key:** Ensure your `.env` file is correctly named and the `NVIDIA_API_KEY` is accurate and has no extra characters or quotes unless they are part of the key itself.

By following these steps, you should be able to successfully test and observe the behavior of the Autonomous LLM Agent. Happy testing!
```
