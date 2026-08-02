import json

import azure.functions as func
from azure.functions.mcp import MCPToolContext

from graph_client import get_profile_response

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


@app.mcp_tool()
async def get_my_profile(context: MCPToolContext) -> str:
    """Return the signed-in user's selected Microsoft Graph profile fields."""
    response = await get_profile_response(context)
    return json.dumps(response, ensure_ascii=False, separators=(",", ":"))


@app.route(
    route="consent-complete",
    methods=["GET"],
    auth_level=func.AuthLevel.ANONYMOUS,
    trigger_arg_name="request",
)
def consent_complete(request: func.HttpRequest) -> func.HttpResponse:
    response = func.HttpResponse(
        "Authentication completed. Return to the chat and try the request again.",
        status_code=200,
        mimetype="text/plain",
        charset="utf-8",
    )
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response