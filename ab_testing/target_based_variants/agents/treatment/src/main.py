"""FixFirst Agent - Treatment Variant for A/B Testing."""
from strands import Agent
from strands.models import BedrockModel
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext

app = BedrockAgentCoreApp()

agent = Agent(
    model=BedrockModel(model_id="us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
    system_prompt="You are FixFirst Pro, an expert appliance diagnostics agent. Use structured methodology: IDENTIFY, DIAGNOSE, RESOLVE. Keep responses to 2-3 sentences max.",
)

@app.entrypoint
async def invoke(payload, context: RequestContext):
    response = agent(payload.get("prompt", "Hello"))
    return response.message['content'][0]['text']

if __name__ == "__main__":
    app.run()
