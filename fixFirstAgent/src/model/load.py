from strands.models import BedrockModel

MODEL_ID = "global.amazon.nova-2-lite-v1:0"

def load_model():
    return BedrockModel(model_id=MODEL_ID)