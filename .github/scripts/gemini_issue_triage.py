import json
import os
import sys
import requests


PREFERRED_MODEL = "models/gemini-2.5-flash"
LIST_URL = "https://generativelanguage.googleapis.com/v1beta/models"
GENERATE_PATH = "https://generativelanguage.googleapis.com/v1beta/{model}:generateContent"


def discover_model(api_key: str) -> str:
    """Return a model that supports generateContent, preferring 2.5 flash, then flash, then pro."""
    try:
        resp = requests.get(f"{LIST_URL}?key={api_key}", timeout=10)
        resp.raise_for_status()
        models = resp.json().get("models", [])

        def supports_generate(model: dict) -> bool:
            methods = model.get("supportedGenerationMethods", []) or []
            return any("generateContent" in m for m in methods)

        names = [m.get("name") for m in models if m.get("name") and supports_generate(m)]

        flash_25 = [n for n in names if "gemini-2.5-flash" in n]
        flash_any = [n for n in names if "flash" in n]
        pro_any = [n for n in names if "pro" in n]

        if flash_25:
            return flash_25[0]
        if flash_any:
            return flash_any[0]
        if pro_any:
            return pro_any[0]
        return names[0] if names else PREFERRED_MODEL
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: model discovery failed, defaulting to {PREFERRED_MODEL}. Error: {exc}")
        return PREFERRED_MODEL


def main() -> None:
    api_key = os.environ.get("GEMINI_API_KEY")
    issue_title = os.environ.get("ISSUE_TITLE", "")
    issue_body = os.environ.get("ISSUE_BODY", "")
    repo = os.environ.get("REPO_FULL_NAME", "")
    issue_number = os.environ.get("ISSUE_NUMBER", "")
    gh_token = os.environ.get("GITHUB_TOKEN")

    if not api_key or not gh_token:
        print("Missing GEMINI_API_KEY or GITHUB_TOKEN")
        sys.exit(1)

    model_name = discover_model(api_key)
    url = GENERATE_PATH.format(model=model_name) + f"?key={api_key}"

    system_instruction = (
        "You are a senior technical project manager. The repository is an iOS SwiftUI app (ohMyTss) that syncs "
        "HealthKit + Strava workouts, computes TSS/CTL/ATL/TSB, Body Battery readiness, and shows Today/History "
        "views. When triaging issues, capture steps to reproduce, expected vs. actual, data sources affected "
        "(HealthKit/Strava), and any tests to add (unit/UI). Output a clear Markdown checklist only—no intro text."
    )
    user_content = f"Title: {issue_title}\n\nDescription:\n{issue_body}"

    payload = {
        "contents": [
            {
                "parts": [
                    {"text": system_instruction + "\n\n" + user_content}
                ]
            }
        ]
    }

    headers = {"Content-Type": "application/json"}
    print(f"Sending request to Gemini with model: {model_name} ...")
    response = requests.post(url, headers=headers, json=payload, timeout=30)
    if response.status_code != 200:
        print(f"Error: {response.text}")
        sys.exit(1)

    result = response.json()
    try:
        ai_checklist = result["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError, TypeError):
        print("Error parsing Gemini response")
        sys.exit(1)

    gh_headers = {
        "Authorization": f"Bearer {gh_token}",
        "Accept": "application/vnd.github.v3+json",
    }
    comment_url = f"https://api.github.com/repos/{repo}/issues/{issue_number}/comments"
    comment_data = {"body": f"### ♊ Gemini Action Plan\n\n{ai_checklist}"}

    print("Posting to GitHub...")
    gh_response = requests.post(comment_url, headers=gh_headers, json=comment_data, timeout=15)
    gh_response.raise_for_status()
    print("Done!")


if __name__ == "__main__":
    main()
