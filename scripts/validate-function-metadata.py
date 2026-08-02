from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    function_path = repo_root / "src" / "function"
    sys.path.insert(0, str(function_path))

    import function_app

    functions = function_app.app.get_functions()
    metadata = [
        {
            "name": function.get_function_name(),
            "bindingTypes": [str(binding.type) for binding in function.get_bindings()],
        }
        for function in functions
    ]
    names = {item["name"] for item in metadata}
    expected = {"get_my_profile", "consent_complete"}
    if not expected.issubset(names):
        missing = sorted(expected - names)
        raise SystemExit(f"Missing indexed functions: {missing}")

    print(json.dumps({"status": "passed", "functions": metadata}, separators=(",", ":")))


if __name__ == "__main__":
    main()
