import os
import posix
import sequtils
import times
import typetraits

type
  FileRight* = enum
    frRead, frWrite, frExecute

const
  readPerm = S_IRUSR or S_IRGRP or S_IROTH
  writePerm = S_IWUSR or S_IWGRP or S_IWOTH
  execPerm = S_IXUSR or S_IXGRP or S_IXOTH

proc getFileRights*(file: string): set[FileRight] =
  if not file.existsFile:
    return {}
  var fileStats: Stat
  if stat(file, fileStats) != 0:
    raiseOSError(osLastError(), "could not check file rights")
  var res: int = 0
  if fileStats.st_uid == getuid():
    res = fileStats.st_mode and S_IRWXU
  elif fileStats.st_gid == getgid():
    res = fileStats.st_mode and S_IRWXG
  else:
    res = fileStats.st_mode and S_IRWXO
  if (res and readPerm) != 0:
    incl result, frRead
  if (res and writePerm) != 0:
    incl result, frWrite
  if (res and execPerm) != 0:
    incl result, frExecute

type
  Timer* = object
    startTime: float

proc start*(t: var Timer) = 
  t.startTime = epochTime()

proc getTime*(t: Timer): float = 
  return epochTime() - t.startTime

proc getFullExceptionMessage*(e: ref Exception): string =
  return $e.name & ": " & e.msg

proc getFullErrorMessage*(msg: string,
                          code: OSErrorCode = OSErrorCode(0)): string =
  if code == OSErrorCode(0):
    return msg
  else:
    return msg & ": " & osErrorMsg(code)

var
  RLIM_INFINITY {.importc, header: "<sys/resource.h>".}: int
  RLIMIT_CORE* {.importc, header: "<sys/resource.h>".}: cint
  RLIMIT_CPU* {.importc, header: "<sys/resource.h>".}: cint
  RLIMIT_AS* {.importc, header: "<sys/resource.h>".}: cint
  RLIMIT_DATA* {.importc, header: "<sys/resource.h>".}: cint
  RLIMIT_STACK* {.importc, header: "<sys/resource.h>".}: cint

proc updateLimit*(resource: cint, value: int): bool =
  result = true
  var rlim: Rlimit
  if getrlimit(resource, rlim) != 0: return false
  if rlim.rlim_max == RLIM_INFINITY:
    rlim.rlim_cur = value
  else:
    rlim.rlim_cur = min(value, rlim.rlim_max)
  rlim.rlim_max = rlim.rlim_cur
  if setrlimit(resource, rlim) != 0: return false

proc redirectDescriptor*(fd: cint, fileName: string, flags: cint,
                        mode: Mode = 0o644): OSErrorCode =
  result = OSErrorCode(0)
  let fname = if len(fileName) == 0: "/dev/null" else: fileName
  let destFd = open(cstring(fname), flags, mode)
  if destFd < 0:
    return osLastError()
  if dup2(destFd, fd) < 0:
    let err = osLastError()
    discard close(destFd)
    return err

when system.hostOS == "linux":
  func clearenv*(): cint {.importc, header: "<stdlib.h>".}
else:
  func unsetenv(name: cstring): cint {.importc, header: "<stdlib.h>".}
  
  func clearenv*(): cint =
    let env = toSeq(envPairs)
    for key, _ in env:
      result |= unsetenv(key)

const
  usecInSecond = 1_000_000;

proc `+`*(val1, val2: Timeval): Timeval =
  result.tv_sec = posix.Time(clong(val1.tv_sec) + clong(val2.tv_sec))
  result.tv_usec = val1.tv_usec + val2.tv_usec
  if result.tv_usec >= usecInSecond:
    inc result.tv_sec
    result.tv_usec -= usecInSecond

proc `-`*(start, finish: Timeval): Timeval =
  result.tv_sec = finish.tv_sec - start.tv_sec
  result.tv_usec = finish.tv_usec - start.tv_usec
  if result.tv_usec < 0:
    dec result.tv_sec
    result.tv_usec += usecInSecond

proc toFloat*(value: Timeval): float =
  return float(value.tv_sec) + value.tv_usec / usecInSecond

when system.hostOS == "macosx":
  const maxRssBytes* = 1
else:
  const maxRssBytes* = 1024
