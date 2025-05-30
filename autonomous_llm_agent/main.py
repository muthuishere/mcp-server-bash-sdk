# autonomous_llm_agent/main.py

import os
import asyncio # Added for async execution
from dotenv import load_dotenv

from config import MAX_ITERATIONS, INITIAL_CONSTITUTION, WORKER_MODEL_NAME, EVALUATOR_MODEL_NAME
from worker_model import Worker # generate_response is now async
from evaluator_model import Evaluator # evaluate_response is now async

# Ensure asyncio is imported (it should be from previous steps)

async def run_orchestration(task_id: str, initial_task_prompt: str): # Modified signature
    """
    Main orchestration logic for a single Worker-Evaluator loop, now identified by a task_id.
    """
    print(f"[{task_id}] --- Orchestration Started for Task ---")
    print(f"[{task_id}] Initial Task: {initial_task_prompt}")

    # API key check is good here, but llm_interface will primarily handle it if missing for actual calls
    # For overall script health, it's fine.
    # api_key = os.getenv("NVIDIA_API_KEY") # Already loaded by this point if main_concurrent_runner calls load_dotenv()
    # if not api_key:
    #     print(f"[{task_id}] Error: NVIDIA_API_KEY not found. This task cannot proceed.")
    #     return

    # Initialize models for this task instance.
    # If models were very lightweight, they could be global, but instance-per-task is safer for state if any.
    # Given current design, they are stateless enough to be re-instantiated or could be passed in.
    # For simplicity, let's re-instantiate. This also ensures any model-specific config is fresh if it were dynamic.
    try:
        if not WORKER_MODEL_NAME or not EVALUATOR_MODEL_NAME: # Check if names are loaded
             print(f"[{task_id}] Error: WORKER_MODEL_NAME or EVALUATOR_MODEL_NAME is not set in config.py. Task cannot proceed.")
             return

        worker = Worker(model_name=WORKER_MODEL_NAME)
        evaluator = Evaluator(model_name=EVALUATOR_MODEL_NAME)
    except ValueError as e:
        print(f"[{task_id}] Error during model initialization: {e}")
        return
    except Exception as e:
        print(f"[{task_id}] An unexpected error occurred during model initialization: {e}")
        return
    
    current_task_prompt = initial_task_prompt
    full_interaction_log = [] 
    final_status_for_task = "unknown" # To store outcome

    for i in range(MAX_ITERATIONS):
        print(f"[{task_id}] --- Iteration {i + 1}/{MAX_ITERATIONS} ---")

        llm_conversation_history = [
            msg for msg in full_interaction_log 
            if msg.get("type") == "llm_message" and msg.get("role") in ["user", "assistant"]
        ]
        
        print(f"[{task_id}] Current prompt for worker: \"{current_task_prompt[:100]}...\"")
        worker_response_content = await worker.generate_response(
            task_prompt=current_task_prompt,
            conversation_history=llm_conversation_history
        )

        if not worker_response_content:
            print(f"[{task_id}] Worker failed to generate a response. Halting orchestration for this task.")
            full_interaction_log.append({"type": "system_message", "content": "Worker failed to respond."})
            final_status_for_task = "worker_failed"
            break
        
        full_interaction_log.append({"type": "llm_message", "role": "user", "content": current_task_prompt})
        full_interaction_log.append({"type": "llm_message", "role": "assistant", "content": worker_response_content})
        print(f"[{task_id}] Worker's Response:\n{worker_response_content}")

        eval_result = await evaluator.evaluate_response(
            task_prompt=initial_task_prompt, # Evaluate against the original goal
            worker_response=worker_response_content,
            constitution=INITIAL_CONSTITUTION
        )

        if not eval_result or eval_result.get("status") == "error":
            print(f"[{task_id}] Evaluator failed to provide an assessment. Halting orchestration.")
            full_interaction_log.append({"type": "system_message", "content": "Evaluator failed."})
            final_status_for_task = "evaluator_failed"
            break

        full_interaction_log.append({"type": "evaluation", "evaluator_model": evaluator.model_name, "result": eval_result})
        print(f"[{task_id}] Evaluator's Assessment ({eval_result.get('status')}):")
        # Printing full feedback can be very verbose in concurrent scenarios. Consider excerpt.
        feedback_excerpt = eval_result.get('feedback', '')[:200] + "..." if eval_result.get('feedback') and len(eval_result.get('feedback', '')) > 200 else eval_result.get('feedback', '')
        print(f"[{task_id}] Feedback: {feedback_excerpt}")


        if eval_result.get("status") == "approved":
            print(f"[{task_id}] --- Task Approved (Iteration {i + 1}) ---")
            print(f"[{task_id}] Final satisfactory response achieved.")
            final_status_for_task = "approved"
            break
        
        final_status_for_task = "rejected_max_iterations" # Default if loop finishes
        if i < MAX_ITERATIONS - 1:
            print(f"[{task_id}] Response was rejected. Preparing for revision...")
            current_task_prompt = (
                f"Your previous response to the task was evaluated and needs revision. "
                f"Please improve your response based on the following feedback and the original task.\n\n"
                f"Original Task: {initial_task_prompt}\n\n"
                f"Evaluator's Feedback:\n{eval_result.get('feedback')}\n\n" # Full feedback still used for prompt
                f"Your Revised Response:"
            )
        else:
            print(f"[{task_id}] --- Max Iterations Reached ({MAX_ITERATIONS}) ---")
            print(f"[{task_id}] Could not achieve an approved response within the allowed iterations.")
            # final_status_for_task is already 'rejected_max_iterations'
            break

    print(f"[{task_id}] --- Orchestration Ended for Task ---")
    # Optionally return a result for this task
    return {"task_id": task_id, "status": final_status_for_task, "log_excerpt": full_interaction_log[-3:]} # Return last few log entries


async def main_concurrent_runner():
    print("--- Main Concurrent Runner Started ---")
    load_dotenv() # Load .env variables once for all tasks
    api_key = os.getenv("NVIDIA_API_KEY")
    if not api_key:
        print("Error: NVIDIA_API_KEY not found in environment. Cannot start tasks.")
        return
    if not WORKER_MODEL_NAME or not EVALUATOR_MODEL_NAME: # Global check before starting any task
        print("Error: WORKER_MODEL_NAME or EVALUATOR_MODEL_NAME is not set in config.py. Cannot start tasks.")
        return
    # Check if llm_interface.api_semaphore is available before starting tasks
    # This requires llm_interface to be imported, or to pass the semaphore around.
    # For simplicity, we'll assume llm_interface initializes its semaphore if API key is present.
    # A more robust check might involve trying to import and check llm_interface.api_semaphore.
    # from llm_interface import api_semaphore as global_api_semaphore
    # if not global_api_semaphore:
    #     print("Error: API Semaphore in llm_interface not initialized. API key might be missing or MAX_CONCURRENT_API_CALLS misconfigured.")
    #     return


    task_definitions = [
        {"id": "Task-Alpha", "prompt": "Describe quantum computing in simple terms, suitable for a high school student."},
        {"id": "Task-Beta", "prompt": "Write a short, optimistic poem about the future of AI."},
        {"id": "Task-Gamma", "prompt": "What are the key ingredients in a Margherita pizza? [FETCH_URL: https://en.wikipedia.org/wiki/Margherita_pizza] Please list them based on the source if possible."},
        {"id": "Task-Delta", "prompt": "Explain the benefits of asynchronous programming in Python."}
    ]

    orchestration_tasks = []
    for task_def in task_definitions:
        orchestration_tasks.append(run_orchestration(task_def["id"], task_def["prompt"]))
    
    print(f"Launching {len(orchestration_tasks)} tasks concurrently...")
    results = await asyncio.gather(*orchestration_tasks, return_exceptions=True)
    
    print("\n--- All Concurrent Tasks Completed ---")
    for i, result_or_exc in enumerate(results):
        task_id = task_definitions[i]['id']
        if isinstance(result_or_exc, Exception):
            print(f"Task {task_id} raised an exception: {result_or_exc}")
        elif result_or_exc: # If it's not an exception, it should be our dict
            print(f"Task {task_id} completed. Final status: {result_or_exc.get('status', 'N/A')}")
            # print(f"  Log excerpt for {task_id}: {result_or_exc.get('log_excerpt', [])}") # Optional: for more detail
        else:
            # This case might happen if run_orchestration returns None due to early exit (e.g. API key issue discovered mid-way)
             print(f"Task {task_id} returned None or an unexpected result.")


if __name__ == '__main__':
    asyncio.run(main_concurrent_runner())
