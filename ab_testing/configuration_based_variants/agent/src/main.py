"""FixFirst Agent - Configuration Bundle Variant for A/B Testing.

This single agent handles both control and treatment variants.
The system prompt is read dynamically from the configuration bundle
injected by the AgentCore Gateway via W3C baggage headers.

Control bundle: conversational style ("Ask one question at a time")
Treatment bundle: structured style ("IDENTIFY, DIAGNOSE, RESOLVE")
"""
from strands import Agent
from strands.models import BedrockModel
from strands.hooks.events import BeforeModelCallEvent
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext
from bedrock_agentcore.runtime import BedrockAgentCoreContext

app = BedrockAgentCoreApp()

DEFAULT_MODEL_ID = "us.amazon.nova-lite-v1:0"
DEFAULT_SYSTEM_PROMPT = (
    "You are FixFirst, a friendly support agent for appliance troubleshooting. "
    "Keep responses short and conversational. Ask one question at a time."
)


def dynamic_config_hook(event: BeforeModelCallEvent):
    """Read config bundle and apply system prompt before every model call.

    During an A/B test, the Gateway assigns each session to a variant and
    propagates the corresponding bundle reference via W3C baggage headers.
    The runtime makes this available through BedrockAgentCoreContext.
    """
    config = BedrockAgentCoreContext.get_config_bundle()
    if config:
        event.agent.system_prompt = config.get("system_prompt", DEFAULT_SYSTEM_PROMPT)


agent = Agent(
    model=BedrockModel(model_id=DEFAULT_MODEL_ID),
    system_prompt=DEFAULT_SYSTEM_PROMPT,
)
agent.hooks.add_callback(BeforeModelCallEvent, dynamic_config_hook)


@app.entrypoint
async def invoke(payload, context: RequestContext):
    response = agent(payload.get("prompt", "Hello"))
    return response.message['content'][0]['text']


if __name__ == "__main__":
    app.run()
