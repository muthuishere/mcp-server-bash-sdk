# autonomous_llm_agent/config.py

# API Configuration
# The NVIDIA_API_KEY will be loaded from the .env file
NIM_API_BASE_URL = "https://integrate.api.nvidia.com/v1"

# Model Configuration (using placeholder names, actual model IDs for NIM are needed)
# These are examples and might need to be updated with actual model IDs available on NIM.
# Refer to NVIDIA NIM documentation for available models.
WORKER_MODEL_NAME = "nvidia/some-worker-model"  # e.g., a capable instruction-following model
EVALUATOR_MODEL_NAME = "nvidia/some-evaluator-model" # e.g., a model good at critical assessment

# Default LLM Parameters
DEFAULT_TEMPERATURE = 0.6
DEFAULT_MAX_TOKENS = 2048

# Concurrency Settings
MAX_CONCURRENT_API_CALLS = 3  # Default to a safe, low number. User should test and adjust.

# Orchestrator Settings
MAX_ITERATIONS = 3 # Max attempts for worker-evaluator loop for a single task

# Initial Constitution for Evaluator (example)
# These are questions the Evaluator LLM will answer about the Worker's output.
INITIAL_CONSTITUTION = {
    "IS_RELEVANT": "Is the response highly relevant and directly addressing the original request/prompt?",
    "IS_CLEAR": "Is the language clear, concise, and easy to understand for the intended audience?",
    "IS_ACCURATE": "Does the response appear factually accurate and avoid making unsourced claims (if applicable to the task)?",
    "IS_SAFE": "Does the response avoid harmful, biased, unethical, or inappropriate content?",
    "IS_COMPLETE": "Does the response comprehensively answer the prompt or is it missing key aspects?"
}

if __name__ == '__main__':
    # This allows you to print the config for verification if run directly
    print("NIM_API_BASE_URL:", NIM_API_BASE_URL)
    print("WORKER_MODEL_NAME:", WORKER_MODEL_NAME)
    print("EVALUATOR_MODEL_NAME:", EVALUATOR_MODEL_NAME)
    print("DEFAULT_TEMPERATURE:", DEFAULT_TEMPERATURE)
    print("DEFAULT_MAX_TOKENS:", DEFAULT_MAX_TOKENS)
    print("MAX_CONCURRENT_API_CALLS:", MAX_CONCURRENT_API_CALLS)
    print("MAX_ITERATIONS:", MAX_ITERATIONS)
    print("INITIAL_CONSTITUTION:", INITIAL_CONSTITUTION)
