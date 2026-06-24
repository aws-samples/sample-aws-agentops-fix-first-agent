"""FixFirst Agent - Control Variant for A/B Testing."""
from strands import Agent
from strands.models import BedrockModel
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext

app = BedrockAgentCoreApp()

agent = Agent(
    model=BedrockModel(model_id="us.amazon.nova-lite-v1:0"),
    system_prompt="You are FixFirst, a friendly support agent for appliance troubleshooting. Keep responses short and conversational. Ask one question at a time.",
)

@app.entrypoint
async def invoke(payload, context: RequestContext):
    response = agent(payload.get("prompt", "Hello"))
    return response.message['content'][0]['text']

if __name__ == "__main__":
    app.run()
