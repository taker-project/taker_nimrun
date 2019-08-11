import macros
import math
import os
import strutils
import tables
import posix
import json
import utils

const
  runnerVersion = "0.1.1"
  runnerVersionNumber = 1

type
  RunnerError* = object of Exception
  RunnerValidateError* = object of RunnerError

  RunStatus* = enum
    rsNone = "none",
    rsOk = "ok",
    rsTimeLimit = "time-limit",
    rsIdleLimit = "idle-limit",
    rsMemoryLimit = "memory-limit",
    rsRuntimeError = "runtime-error",
    rsSecurityError = "security-error",
    rsRunFail = "run-fail",
    rsRunning = "running"

  IsolatePolicy* = enum
    ipNone = "none",
    ipNormal = "normal",
    ipCompile = "compile",
    ipStrict = "strict"

  Parameters* = object
    timeLimit*, idleLimit*, memoryLimit*: float
    clearEnv*: bool
    executable*: string
    env*: Table[string, string]
    args*: seq[string]
    workingDir*, stdinRedir*, stdoutRedir*, stderrRedir*: string
    isolateDir*: string
    isolatePolicy*: IsolatePolicy

  RunResults = object
    time*, clockTime*, memory*: float
    exitcode*, signal*: int
    status*: RunStatus
    comment*: string
  
  ProcessRunner = object
    parameters*: Parameters
    mResults: RunResults
    pid: Pid
    pipe: array[0..1, cint]
    timer: utils.Timer

using
  rr: var ProcessRunner

macro validateAssert(expr: untyped): untyped =
  expr.expectKind nnkInfix
  let exprString = expr.toStrLit
  result = quote do:
    if not `expr`:
      raise newException(RunnerValidateError, "assertion failed: " & `exprString`)

proc validate*(p: Parameters) =
  validateAssert p.workingDir.len == 0 or dirExists(p.workingDir)

  let oldDirName = if len(p.workingDir) != 0: getCurrentDir() else: ""
  defer:
    if len(oldDirName) != 0:
      setCurrentDir(oldDirName)  
  if len(p.workingDir) != 0:
    setCurrentDir(p.workingDir)
  
  validateAssert p.timeLimit > 0
  validateAssert p.idleLimit > 0
  validateAssert p.memoryLimit > 0
  validateAssert p.memoryLimit > 0
  validateAssert frExecute in getFileRights(p.executable)
  validateAssert len(p.stdinRedir) == 0 or frRead in getFileRights(p.stdinRedir)

let
  defaultParameters* = Parameters(timeLimit: 2.0, idleLimit: 7.0,
                                  memoryLimit: 256.0, clearEnv: false,
                                  isolatePolicy: ipNormal)

proc convertName(name: string, forward: bool): string =
  if forward:
    for c in name:
      if c in {'A'..'Z'}:
        result &= '-' & c.toLowerAscii
      else:
        result &= c
  else:
    var dash = false
    for c in name:
      if c == '-':
        dash = true
      elif dash:
        result &= c.toUpperAscii
        dash = false
      else:
        result &= c

proc convertJson(node: JsonNode, forward: bool): JsonNode =
  assert node.kind == JObject
  result = newJObject()
  for key, value in node.pairs:
    result[key.convertName(forward)] = value
    result[key.convertName(forward)] = value

proc fillDefaultFields(node: var JsonNode) =
  let defaultJson = %defaultParameters
  for key, value in defaultJson:
    if key notin node:
      node[key] = value

proc loadFromJson*(p: var Parameters, j: JsonNode) = 
  var convertedJson = j.convertJson(false)
  convertedJson.fillDefaultFields
  p = to(convertedJson, Parameters)

proc loadFromJsonStr*(p: var Parameters, s: string) = 
  p.loadFromJson(s.parseJson)

proc saveToJson*(r: RunResults): JsonNode = (%r).convertJson(true)
proc saveToJsonStr*(r: RunResults): string = r.saveToJson.pretty

var
  gActiveChild: Pid = 0

proc termSignal(_: cint) {.noconv.} =
  if gActiveChild != 0:
    discard kill(gActiveChild, SIGKILL)
  discard kill(0, SIGKILL)

type
  ActiveChildLock = object
    locked: bool
    oldActions: array[3, Sigaction]

proc newChildLock(pid: Pid): ActiveChildLock =
  assert gActiveChild == 0, "active child already set"
  gActiveChild = pid
  var sigHandler: Sigaction
  sigHandler.sa_handler = termSignal
  discard sigaction(SIGINT, sigHandler, result.oldActions[0])
  discard sigaction(SIGTERM, sigHandler, result.oldActions[1])
  discard sigaction(SIGQUIT, sigHandler, result.oldActions[2])
  result.locked = true

proc unlock(lock: var ActiveChildLock) =
  assert lock.locked
  gActiveChild = 0
  discard sigaction(SIGINT, lock.oldActions[0], nil)
  discard sigaction(SIGTERM, lock.oldActions[1], nil)
  discard sigaction(SIGQUIT, lock.oldActions[2], nil)
  lock.locked = false

proc results*(rr): RunResults = rr.mResults

proc newProcessRunner*(): ProcessRunner =
  ProcessRunner(parameters: defaultParameters, pid: -1)

proc runnerInfoJson*(rr): JsonNode =
  %* {
    "name": "Nim Runner for UNIX",
    "description": "taker_unixrun rewritten on Nim language. Suitable for " &
                   "UNIX-like systems (like GNU/Linux, macOS and FreeBSD)",
    "author": "Alexander Kernozhitsky",
    "version": runnerVersion,
    "version-number": runnerVersionNumber,
    "license": "GPL-3+",
    "features": @[]
  }

proc childFailure(rr: ProcessRunner, message: string,
                  errcode: OSErrorCode = OSErrorCode(0)) {.noreturn.} =
  var fullMsg = getFullErrorMessage(message, errcode)
  var msgSize = len(fullMsg)
  discard write(rr.pipe[1], addr msgSize, sizeof(msgSize))
  discard write(rr.pipe[1], cstring(fullMsg), msgSize * sizeof(char))
  discard close(rr.pipe[1])
  exitnow(42)

proc parentFailure(rr: ProcessRunner, message: string,
                   errcode: OSErrorCode = OSErrorCode(0)) =
  if errcode == OSErrorCode(0):
    raise newException(RunnerError, message)
  else:
    raiseOSError(errcode, message)

proc trySyscall(rr: ProcessRunner, success: bool, errorName: string) =
  if success: return
  if rr.pid == 0:
    rr.childFailure(errorName, osLastError())
  else:
    rr.parentFailure(errorName, osLastError())

when system.hostOS == "linux":
  proc updateTimeFromProcStat(rr): bool =
    result = true
    try:
      var procStats: File
      if not procStats.open("/proc/" & $rr.pid & "/stat"): return false
      defer: procStats.close
      var procStr = procStats.readLine
      let bracketPos = procStr.rfind(')')
      if bracketPos < 0: return false
      procStr.delete(0, bracketPos)
      let
        tokens = procStr.splitWhitespace
        utime = tokens[11].parseBiggestUInt
        stime = tokens[12].parseBiggestUInt
      rr.mResults.time = float(utime + stime) / float(sysconf(SC_CLK_TCK))
    except:
      result = false

  proc updateMemFromProcStatus(rr): bool =
    result = false
    try:
      const
        multipliers: Table[string, float] = {
          "kb": 1.0 / 1024,
          "mb": 1.0,
          "gb": 1024.0
        }.toTable
      var procStatus: File
      if not procStatus.open("/proc/" & $rr.pid & "/status"): return false
      defer: procStatus.close
      for line in procStatus.lines:
        let
          parsed = line.splitWhitespace
          fieldName = if len(parsed) == 0: "" else: parsed[0]
        case fieldName:
        of "VmPeak:":
          if len(parsed) != 3: return false
          let
            value = parsed[1].parseBiggestInt
            measureUnit = parsed[2].toLowerAscii
          if measureUnit notin multipliers: return false
          rr.mResults.memory = max(rr.mResults.memory,
                                   float(value) * multipliers[measureUnit])
          return true
        else: discard
    except:
      result = false

proc updateResultsOnRun(rr) = 
  when system.hostOS == "linux":
    discard rr.updateTimeFromProcStat
    discard rr.updateMemFromProcStatus
  rr.mResults.clockTime = rr.timer.getTime

proc updateVerdicts(rr) =
  if rr.mResults.time > rr.parameters.timeLimit:
    rr.mResults.status = rsTimeLimit
  if rr.mResults.clockTime > rr.parameters.idleLimit:
    rr.mResults.status = rsIdleLimit
  if rr.mResults.memory > rr.parameters.memoryLimit:
    rr.mResults.status = rsMemoryLimit

proc updateResultsOnTerminate(rr: var ProcessRunner,
                              resources: Rusage, status: cint) =
  if WIFEXITED(status):
    rr.mResults.exitcode = WEXITSTATUS(status)
    if rr.mResults.exitcode == 0:
      rr.mResults.status = rsOK
    else:
      rr.mResults.status = rsRuntimeError
  if WIFSIGNALED(status):
    rr.mResults.signal = WTERMSIG(status)
    rr.mResults.status = rsRuntimeError
  rr.mResults.time = toFloat(resources.ru_stime + resources.ru_utime)
  rr.mResults.clockTime = rr.timer.getTime
  if rr.mResults.memory == 0:
    # FIXME : if the memory usage wasn't updated, maybe use smth better than
    # maxrss?
    rr.mResults.comment = "memory measurement is not precise!"
    rr.mResults.memory = float(resources.ru_maxrss) / 1048576.0 * maxRssBytes

proc handleChild(rr) {.noreturn.} =
  discard setsid()
  
  rr.trySyscall(updateLimit(RLIMIT_CORE, 0), "could not disable core dumps")
  
  # FIXME : avoid overflow when handling very large time and memory limits
  
  let integralTimeLimit = toInt(ceil(rr.parameters.timeLimit + 0.2))
  rr.trySyscall(updateLimit(RLIMIT_CPU, integralTimeLimit),
                "could not set time limit")

  # FIXME : distinguish between RE and ML better

  let memLimitBytes = toInt(ceil(rr.parameters.memoryLimit * 1048576))
  rr.trySyscall(updateLimit(RLIMIT_AS, memLimitBytes * 2),
                "could not set memory limit")
  rr.trySyscall(updateLimit(RLIMIT_DATA, memLimitBytes * 2),
                "could not set memory limit")
  rr.trySyscall(updateLimit(RLIMIT_STACK, memLimitBytes * 2),
                "could not set memory limit")

  if len(rr.parameters.workingDir) != 0:
    rr.trySyscall(chdir(cstring(rr.parameters.workingDir)) == 0,
                  "could not change directory")

  var err: OSErrorCode

  err = redirectDescriptor(STDIN_FILENO, rr.parameters.stdinRedir, O_RDONLY)
  if err != OSErrorCode(0):
    rr.childFailure("unable to redirect stdin into \"" &
                    rr.parameters.stdinRedir & "\"", err)
  err = redirectDescriptor(STDOUT_FILENO, rr.parameters.stdoutRedir,
                               O_CREAT or O_TRUNC or O_WRONLY)

  if err != OSErrorCode(0):
    rr.childFailure("unable to redirect stdout into \"" &
                    rr.parameters.stdoutRedir & "\"", err)

  err = redirectDescriptor(STDERR_FILENO, rr.parameters.stderrRedir,
                               O_CREAT or O_TRUNC or O_WRONLY)
  if err != OSErrorCode(0):
    rr.childFailure("unable to redirect stderr into \"" &
                     rr.parameters.stderrRedir & "\"", err)

  if rr.parameters.clearEnv:
    rr.trySyscall(clearenv() == 0, "could not clear environment")
  for key, value in rr.parameters.env:
    putEnv(key, value)

  var argv = allocCStringArray(rr.parameters.executable & rr.parameters.args)
  rr.trySyscall(execv(argv[0], argv) == 0,
                "failed to run \"" & rr.parameters.executable & "\"")
  rr.childFailure("handleChild() has reached the end")

proc handleParent(rr) =
  defer: discard close rr.pipe[0]
  rr.timer.start
  
  # check for RUN_FAIL
  var msgSize: int
  let bytesRead = read(rr.pipe[0], addr msgSize, sizeof(msgSize))
  if bytesRead < 0:
    rr.parentFailure("unable to read from pipe", osLastError())
  if bytesRead > 0:
    if bytesRead != sizeof(msgSize):
      rr.parentFailure("unexpected child/parent protocol error")
    var message = newString(msgSize)
    let bytesExpected = sizeof(char) * msgSize
    rr.trySyscall(read(rr.pipe[0], addr message[0], bytesExpected) == bytesExpected,
                  "unexpected child/parent protocol error (message length" &
                  " must be " & $bytesExpected & ", not " & $bytesRead & ")")
    rr.mResults.status = rsRunFail
    rr.mResults.comment = message
    var wstatus: cint
    discard waitpid(rr.pid, wstatus, 0)
    return

  # initialize results
  rr.mResults = RunResults(exitcode: 0, signal: 0, time: 0.0, clockTime: 0.0,
                           memory: 0.0, status: rsRunning)

  # wait for process
  while rr.mResults.status == rsRunning:
    # check for time and memory limits
    rr.updateResultsOnRun
    rr.updateVerdicts
    if rr.mResults.status != rsRunning:
      discard kill(rr.pid, SIGKILL)
      var wstatus: cint
      rr.trySyscall(waitpid(rr.pid, wstatus, 0) >= 0, "unable to wait for process")
      break
    # check if the process has terminated
    var
      status: cint = -1
      resources: Rusage
    let pidWaited = wait4(rr.pid, addr status, WNOHANG or WUNTRACED,
                          addr resources)
    if pidWaited == -1:
      # wait4() error
      let errCode = osLastError()
      discard kill(rr.pid, SIGKILL)
      rr.parentFailure("unable to wait for process", errCode)
    if pidWaited != 0:
      # the process has changed the state
      # FIXME : handle stopped/continued processes
      rr.updateResultsOnTerminate(resources, status)
      if rr.mResults.status == rsRunning:
        discard kill(rr.pid, SIGKILL)
        var wstatus: cint
        discard waitpid(rr.pid, wstatus, 0)
        rr.parentFailure(
              "unexpected process status: waitpid() returned, " &
              "but the process is still alive (status = " & $status % ")")
      rr.updateVerdicts
      break
    # wait a little
    discard usleep(1_000)

when system.hostOS == "linux" or system.hostOS == "freebsd":
  var O_CLOEXEC {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
  
  proc pipe2(pipe: var array[2, cint],
             options: cint): cint {.header: "<unistd.h>", importc.}
else:
  proc pipe2(pipe: var array[2, cint], options: cint): cint =
    # pipe2 emulation for platforms that don't support it
    let res = (pipe(pipe) != 0 or
               fcntl(pipe[0], F_SETFD, FD_CLOEXEC) != 0 or
               fcntl(pipe[1], F_SETFD, FD_CLOEXEC) != 0)
    return if res: 0 else: -1 

proc doExecute(rr) =
  rr.parameters.validate
  rr.mResults = RunResults()
  rr.mResults.status = rsRunning
  if pipe2(rr.pipe, O_CLOEXEC) != 0:
    raiseOSError(osLastError(), "unable to create pipe")
  rr.pid = fork()
  if rr.pid < 0:
    let errCode = osLastError()
    discard close(rr.pipe[0])
    discard close(rr.pipe[1])
    raiseOSError(errCode, "unable to fork()")
  if rr.pid == 0:
    discard close(rr.pipe[0])
    try:
      rr.handleChild
    except:
      rr.childFailure(getCurrentException().getFullExceptionMessage)
  var lock = newChildLock(rr.pid)
  defer: lock.unlock
  discard close(rr.pipe[1])
  rr.handleParent

proc execute*(rr) =
  if rr.results.status == rsRunning:
    raise newException(RunnerError, "process is already running")
  try:
    rr.doExecute
  except:
    rr.mResults.status = rsRunFail
    rr.mResults.comment =  getCurrentException().getFullExceptionMessage
