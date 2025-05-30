#!/bin/bash

# ##############################################################################
# Script Name: call_nim_llm.sh
# Description: A bash script to interact with the NVIDIA NIM Large Language
#              Model API for chat completions, supporting streaming responses.
#
# Prerequisites:
#   - curl: For making HTTP requests.
#   - Common Unix utilities: sed, grep, xargs, echo, read.
#
# Usage:
#   1. Make the script executable (if you haven't already):
#      chmod +x call_nim_llm.sh
#
#   2. Set the NVIDIA API Key environment variable:
#      export NVIDIA_API_KEY="YOUR_NVIDIA_API_KEY_HERE"
#      (Replace YOUR_NVIDIA_API_KEY_HERE with your actual NVIDIA API key.
#      Ensure the key is correctly quoted if it contains special characters.)
#      Alternatively, you can add this line to your ~/.bashrc or ~/.zshrc
#      for persistence across sessions, then source the file (e.g., source ~/.bashrc).
#
#   3. Run the script with your prompt as a command-line argument:
#      ./call_nim_llm.sh "What is the capital of France?"
#
# Example:
#   export NVIDIA_API_KEY="nvapi-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
#   ./call_nim_llm.sh "Write a short story about a robot learning to paint."
#
# Important:
#   - The script requires the NVIDIA_API_KEY environment variable to be set.
#   - If your prompt contains spaces or special characters, enclose it in quotes.
#   - The script uses 'set -o pipefail' to ensure that errors in the curl
#     command are properly caught even when piped.
# ##############################################################################

set -o pipefail

# Check if NVIDIA_API_KEY environment variable is set
if [ -z "$NVIDIA_API_KEY" ]; then
  echo "Error: NVIDIA_API_KEY environment variable is not set." >&2
  echo "Please set it before running the script, e.g.:" >&2
  echo "export NVIDIA_API_KEY=\"your_api_key_here\"" >&2
  exit 1
fi

# Check if a command-line argument is provided
if [ $# -eq 0 ]; then
  echo "Usage: $0 <prompt>" >&2
  exit 1
fi

# Use the first command-line argument as the prompt
user_prompt="$1"

# Call the LLM API using curl and process the streaming response.
# -s: Silent mode (don't show progress meter or error messages from curl itself).
# -N: No buffering (important for streaming).
# -X POST: Specifies the HTTP POST method.
# -H: Adds headers for Authorization and Content-Type.
# -d @-: Reads data for the POST request from stdin (the here document).
# The output is piped to a while loop for line-by-line processing of the stream.
curl -s -N -X POST \
  "https://integrate.api.nvidia.com/v1/chat/completions" \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  -H "Content-Type: application/json" \
  -d @- <<EOF | while IFS= read -r line; do
{
  "model": "deepseek-ai/deepseek-r1",
  "messages": [
    {
      "role": "user",
      "content": "$user_prompt"
    }
  ],
  "temperature": 0.6,
  "top_p": 0.7,
  "max_tokens": 4096,
  "stream": true
}
EOF
    if [[ "$line" == "data: "* ]]; then
        json_data="${line#data: }"
        # Trim whitespace
        json_data_trimmed="$(echo "$json_data" | xargs)"

        if [[ "$json_data_trimmed" == "[DONE]" ]]; then
            break
        fi

        if [[ -n "$json_data_trimmed" ]]; then
            # Attempt to extract content using sed.
            # This specifically targets the 'content' field within the 'delta' object of the first choice.
            # Example of a typical data chunk:
            # data: {"id":"cmpl-xxxx","object":"chat.completion.chunk","created":1234,"model":"model-name","choices":[{"index":0,"delta":{"content":" example"},"finish_reason":null}]}
            # Example of a chunk indicating start of assistant's turn (no printable content):
            # data: {"id":"cmpl-xxxx","object":"chat.completion.chunk","created":1234,"model":"model-name","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}
            
            extracted_content=$(echo "$json_data_trimmed" | sed -n 's/.*"choices":\[{"index":0,"delta":{"content":"\([^"]*\)"}.*/\1/p')

            # Check if content was extracted.
            # If extracted_content is empty, it might be due to:
            # 1. The delta chunk not containing a "content" field (e.g., it's a role update).
            # 2. The "content" field being present but empty ("").
            # 3. An issue with the sed pattern or JSON structure.
            if [[ -n "$extracted_content" ]]; then
                # Decode JSON string escape sequences (e.g., \n, \t, \", \\, \uXXXX).
                # Bash's 'echo -e' can handle common C-style escapes like \n, \t.
                # For \uXXXX (Unicode), a more robust solution like jq or perl would be needed if these are common.
                # For this script, we'll assume simple escapes that echo -e can handle.
                # If \uXXXX sequences are frequent and need proper display, consider adding jq:
                # decoded_content=$(echo "$json_data_trimmed" | jq -r '.choices[0].delta.content // empty')
                # echo -n "$decoded_content"
                
                # Using echo -e for basic escapes.
                # Note: This is a simplification. True JSON string decoding is more complex.
                printf "%b" "$extracted_content"
            fi
        fi
    fi
done
pipeline_status=$?

echo # Print a final newline to ensure the prompt is on a new line after output.

# Check if the pipeline (primarily curl) exited with an error.
if [ "$pipeline_status" -ne 0 ]; then
  echo -e "\nError: API request failed." >&2
  echo "Possible reasons: network issue, invalid API key, server error." >&2
  echo "Curl exit code: $pipeline_status" >&2
fi
