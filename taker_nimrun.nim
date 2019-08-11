import json
import os
import processrunner

var runner = newProcessRunner()

if paramCount() == 1 and paramStr(1) == "-?":
  echo runner.runnerInfoJson.pretty
  quit(0)

let jsonStr = stdin.readAll
runner.parameters.loadFromJsonStr(jsonStr)
runner.execute
echo runner.results.saveToJsonStr
