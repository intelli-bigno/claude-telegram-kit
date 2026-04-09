{
  "hooks": {
    "Stop": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "bash {on_stop_path}"
          }
        ]
      }
    ]
  }
}
