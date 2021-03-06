local log = require("log")
_ENV.log = log

local gateway = require("gateway")
local config = require("config")
local db = require("influxdb")
local rules = require("rules")
local replay = require("replay")
local heartbeat = require("heartbeat")
local sms = require("sms")
local report = require("report")
local listen = require("listener")
local shell = require("shell")
local logo = require("logo")

local listening = false
local manualMode = false

local cfgFilePath = "./config/config.toml"
local cfg = config.getConfig(cfgFilePath)

local function writeEventToDB(level, msg, info)
  if cfg.influxDB.enabled then
    db.pushEvent("event", level, info.short_src, msg)
    if cfg.influxDB.udp.enabled then
      db.postUDP(cfg.influxDB.host, cfg.influxDB.udp.events)
    else
      db.post(cfg.influxDB.host, cfg.influxDB.port, cfg.influxDB.events)
    end
  end
end

local function writeMsgToDB(msgResolved, valueId)
  if cfg.influxDB.enabled then
    if cfg.fixup[valueId] ~= nil then
      local values = cfg.fixup[valueId]
      local fixedValue = values[msgResolved[valueId]]
      msgResolved[valueId] = fixedValue
    end
    db.push(msgResolved, valueId)
    if cfg.influxDB.udp.enabled then
      db.postUDP(cfg.influxDB.host, cfg.influxDB.udp.sensors)
    else
      db.post(cfg.influxDB.host, cfg.influxDB.port, cfg.influxDB.db)
    end
  end
end

local function writeSingleValueToDB(measurement, tag, value)
  if cfg.influxDB.enabled then
    db.pushSingleValue(measurement, tag, value)
    if cfg.influxDB.udp.enabled then
      db.postUDP(cfg.influxDB.host, cfg.influxDB.udp.sensors)
    else
      db.post(cfg.influxDB.host, cfg.influxDB.port, cfg.influxDB.db)
    end
  end
end

local function onData(data)
  log.trace(string.format("Packet: %s", data))
  
  if not cfg.serial.enabled and not cfg.replay.enabled then
    log.debug(string.format("Ignoring: %s", data))
    return
  end
  
  if not listening and data == "Listening" then
    log.info(data)
    listening = true
    return
  end
  
  if cfg.replay.record then
    replay.record(data)
  end
  
  local msg = rules.decode(data)
  local msgResolved = rules.resolve(msg, cfg)
  if msg.node ~= nil and msg.tx == nil and msg.t ~= nil and msgResolved.node ~= nil then
    -- sensor data was received...
    heartbeat.pulse(msgResolved.node)
    
    local _rulesNode = cfg.control[msgResolved.node]
    if _rulesNode == nil then
      log.warn(string.format("Config out of sync! Invalid node %s referenced in packet: %s", msg.node, data))
      return
    end
    
    local _rules = _rulesNode[msgResolved.t]
    if _rules == nil then
      log.warn(string.format("Config out of sync! Invalid type %s referenced in packet: %s", msg.t, data))
      return
    end

    local anyCommandSent = false
    
    if _rules ~= nil then
      local ruleIndex = 0
      local commandSent = false
      local lastValueName = ""
      local valueNameChanged = false
      
      while true do
        local rule = cfg.control[msgResolved.node][msgResolved.t][tostring(ruleIndex)]

        if rule == nil then
          break
        end
        
        rule.node = msgResolved.node

        if lastValueName ~= rule.value then
          lastValueName = rule.value
          valueNameChanged = true
          commandSent = false
        else
          valueNameChanged = false
        end

        if rule.cmd ~= nil then
          if not valueNameChanged and commandSent then
            log.info(string.format("Command already fired. Skipping default rule action: %s.%s.%s", msgResolved.node, msgResolved.t, ruleIndex))
            goto next
          end
        end
        
        log.info(string.format("Sensor rule: %s.%s.%s", msgResolved.node, msgResolved.t, ruleIndex))
        
        if not manualMode and rules.eval(rule, msgResolved, gateway, cfg) then
          commandSent = true
          anyCommandSent = true
        end

      ::next::
        if valueNameChanged then
          if msgResolved.actualValue ~= nil and rule.state == nil then
            writeMsgToDB(msgResolved, rule.value)
            report.update(msgResolved.node, rule.value, msgResolved.actualValue)
          elseif rule.state ~= nil then
            writeMsgToDB(msgResolved, rule.state)
            report.update(msgResolved.node, msgResolved[rule.value], rule.value, rule.state, msgResolved[rule.state])
          end
        end
      
        ruleIndex = ruleIndex + 1
      end

      if not manualMode and not anyCommandSent and _rules.cmd ~= nil then
        log.trace(string.format("Executing default action for %s.%s: %s", msgResolved.node, msgResolved.t, _rules.cmd))
        rules.sendCommand(_rules.cmd, gateway, cfg)
      end
    end

    if cfg.control.signal ~= nil then
      local rule = cfg.control.signal
      rule.node = msgResolved.node
      log.info(string.format("Signal rule: %s.%s", msgResolved.node, rule.value))
      rules.eval(rule, msgResolved, gateway, cfg)
      writeMsgToDB(msgResolved, rule.value)
    end

  elseif msg.node ~= nil and msg.tx ~= nil and msg.t == nil then
    -- a command ack/nak was received...
    gateway.retry(msg)
    writeSingleValueToDB("tx", msgResolved.node, msgResolved.tx)
  else
    log.warn(string.format("Discarded: %s", data))
  end
end

local function onShellMsg(line)
  line = string.lower(line)
  log.warn(string.format("Shell command: %s", line))
  local opts = shell.parse(line)
  if opts.q ~= nil and opts.q == "report" then
    return report.report(cfg)
  elseif opts.w ~= nil then
    local _, wOpt = string.find(line, "-w")
    if wOpt ~= nil and #line > (wOpt + 2) then
      log.log(string.sub(line, wOpt + 2))
    end
  elseif opts.m ~= nil then
    if opts.m == "manual" then
      manualMode = true
    else
      manualMode = false
    end
    log.warn(string.format("Switched to '%s' mode", opts.m))
  elseif opts.n ~= nil and opts.s ~= nil and (opts.r ~= nil or opts.v ~= nil) then
    local cmdFinal = rules.sendCommand(line, gateway, cfg)
    if cmdFinal ~= nil then
      log.warn(string.format("Sent shell command: %s", cmdFinal))
    else
      local err = string.format("Bad param(s) / duplicate command: %s, cmdFinal: %s", line, cmdFinal)
      log.error(err)
      return err
    end
  else
    local err = string.format("Invalid shell command: %s", line)
    log.error(err)
    return err
  end
  return "ok"
end

local function onSmsMsg(from, body)
  local _ = from
  local reply = onShellMsg(body)
  if reply ~= nil then
    sms.send(cfg, reply)
  end
end

local function getNextTime()
  return os.time() + cfg.control.tick.freqSec
end

local nextTime = getNextTime()

local function onIdle()
  if config.isChanged() then
    log.warn("Config changed! Restarting...")
    cfg = config.getConfig(cfgFilePath)
    gateway.stop()
    rules.resetAlerts()
    return
  end
  sms.receive(cfg, onSmsMsg)
  if cfg.shell.enabled then
    listen.receive(onShellMsg)
  end
  if os.time() >= nextTime then
    log.info(string.format("Tick: %s", cfg.control.tick.freqSec))
    if listening and cfg.control.timers ~= nil then
      
      if not manualMode then
        heartbeat.elapseTime(cfg.control.tick.freqSec)
      end
      
      for timerName, timer in pairs(cfg.control.timers) do
  
        local commandSent = false
        local ruleIndex = 0
        
        while true do
          local rule = timer[tostring(ruleIndex)]
          
          if rule == nil then
            break
          end
          
          log.info(string.format("Timer rule: %s.%s", timerName, ruleIndex))
          
          if timer.cmd ~= nil then
            rule.defaultCmd = timer.cmd
          end
          
          if not manualMode and rules.eval(rule, {ts=os.time()}, gateway, cfg) then
            commandSent = true
          end
            
          ruleIndex = ruleIndex + 1
        end
          
        if not manualMode and not commandSent and timer.cmd ~= nil then
          log.trace(string.format("Default Cmd: %s", timer.cmd))
          rules.sendCommand(timer.cmd, gateway, cfg)
        end
        
      end
    end
    
    nextTime = getNextTime()
    
  elseif listening and cfg.replay.enabled then
    local data = replay.getNext()
    if data ~= nil then
      log.debug(string.format("Replay %s", data))
      onData(data)
    end
  end
end

log.info("The Humble Roots Project")
log.info(logo.get("./ascii_lf.drg"))
log.info("Copyright (c) 2015-2018 by Fabien Royer")

--require("mobdebug").start()

while true do
  listening = false
  db.initialize()
  _ENV.log.level = cfg.log.level
  if cfg.log.file ~= nil then
    _ENV.log.outfile = cfg.log.file
  end
  log.callback = writeEventToDB
  log.warn("Gateway started")
  heartbeat.initialize(cfg)
  listen.initialize(cfg.shell.bind, cfg.shell.port)
  if cfg.replay.record then
    replay.setRecordDuration(cfg.replay.recordDuration)
  end
  if cfg.serial.enabled then
    local result, errorDetails = pcall(gateway.run, cfg.serial.port, cfg.serial.baudrate, onData, onIdle)
    if not result then
      log.fatal(errorDetails)
      _ENV.io.Serial.del_us(1000000)
    end
  else
    listening = true
    gateway.resetStopEvent()
    while not gateway.isStopped() do
      onIdle()
      _ENV.io.Serial.del_us(10)
    end
  end
  
  listen.shutdown()
  log.warn("Gateway stopped")
  db.shutdown()
end
