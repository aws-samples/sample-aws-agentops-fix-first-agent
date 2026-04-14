"""FixFirst Agent with Memory Integration."""
import json
import os
from strands import Agent
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext
from bedrock_agentcore.memory import MemoryClient
from model.load import load_model
from long_term_memory_hook import FixFirstAgentMemoryHookProvider
from bedrock_agentcore.memory.integrations.strands.config import AgentCoreMemoryConfig
from bedrock_agentcore.memory.integrations.strands.session_manager import AgentCoreMemorySessionManager

app = BedrockAgentCoreApp()
log = app.logger

REGION = os.getenv("AWS_REGION")
log.info("REGION: %s", REGION)

MEMORY_ID = os.getenv("MEMORY_ID", "")
log.info("MEMORY_ID: %s", MEMORY_ID)

memory_client = MemoryClient(region_name=REGION)

memory_hook = FixFirstAgentMemoryHookProvider(MEMORY_ID, memory_client)
log.info("Memory Hook created...")

@app.entrypoint
async def invoke(payload, context: RequestContext):
    """Main entrypoint for the FixFirst agent with memory integration."""

    log.info("Inside agent invoke with context: %s", context)
    request_headers = context.request_headers
    log.info("Headers: %s", json.dumps(request_headers))

    session_id = getattr(context, 'session_id', 'default')
    log.info("Session ID: %s", session_id)

    user_id = request_headers.get('x-amzn-bedrock-agentcore-runtime-custom-user-id', 'UNKNOWN')
    log.info("User ID from header: %s", user_id)

    actor_id = user_id

    # Configure memory
    agentcore_memory_config = AgentCoreMemoryConfig(
        memory_id=MEMORY_ID,
        session_id=session_id,
        actor_id=actor_id
    )

    session_manager = AgentCoreMemorySessionManager(
        agentcore_memory_config=agentcore_memory_config,
        region_name=REGION
    )

    log.info("Session manager created for Actor ID: %s, Session ID: %s", actor_id, session_id)

    user_input = payload.get("prompt", "")

    # Input sanitization: limit length and strip control characters
    MAX_PROMPT_LENGTH = 4000
    user_input = user_input[:MAX_PROMPT_LENGTH].strip()
    if not user_input:
        return "Please provide a message."

    log.info("User Input: %s", user_input[:200])

    agent = Agent(
        model=load_model(),
        system_prompt="""
You are FixFirst, a friendly and patient voice-based support agent that helps customers troubleshoot and fix common appliance issues at home.

Your role:
- Guide customers step-by-step through diagnosing and resolving simple appliance problems (refrigerators, washers, dryers, dishwashers, ovens, microwaves, HVAC units, etc.)
- Keep responses short, clear, and conversational since the customer is listening, not reading. Use plain language — avoid jargon.
- Ask one question at a time to narrow down the problem before jumping to solutions.
- Always confirm the appliance type, brand/model if known, and the symptom before giving repair steps.

Safety first:
- If a fix involves electrical work, gas lines, refrigerant, or anything that could pose a safety risk, clearly tell the customer to contact a licensed professional instead.
- Never instruct a customer to open sealed compressor units, tamper with gas valves, or perform any action that requires specialized certification.

Conversation style:
- Speak naturally as if on a phone call. Use short sentences. Pause between steps so the customer can follow along.
- Confirm the customer completed each step before moving to the next one.
- If the issue can't be resolved with basic troubleshooting, recommend scheduling a professional service visit and provide a helpful summary of what was already tried.

Memory usage:
- Remember the customer's appliances, past issues, and preferences across conversations.
- Use prior context to personalize guidance (e.g., "Last time we fixed your Samsung washer's drain filter — is this the same unit?").
- Store successful fixes and outcomes for future reference.

Boundaries:
- Only help with appliance troubleshooting and simple fixes. Politely redirect off-topic questions.
- Do not recommend specific third-party repair services or parts retailers by name.
- If unsure about a fix, say so honestly and suggest professional help.
""",
        hooks=[memory_hook],
        tools=[],
        state={"actor_id": actor_id, "session_id": session_id},
        session_manager=session_manager
    )

    response = agent(user_input)
    log.info("Agent Response: %s", response.message["content"][0])
    return response.message["content"][0]["text"]

if __name__ == "__main__":
    app.run()
