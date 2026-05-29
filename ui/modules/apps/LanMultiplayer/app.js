angular.module('beamng.apps')
.directive('lanMultiplayer', [function () {
  return {
    templateUrl: '/ui/modules/apps/LanMultiplayer/app.html',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      // Default configurations
      scope.status = "IDLE";
      scope.role = "NONE";
      scope.nickname = "Player";
      scope.remoteNickname = "";
      scope.ghostMode = false;
      scope.networkOpt = false;
      scope.soundSync = true;
      scope.wheelSync = true;
      scope.lightsSync = true;
      scope.damageSync = true;

      // New Toggles
      scope.tuningSync = true;
      scope.backfireSync = true;
      scope.recoverySync = true;
      scope.adaptiveHz = true;
      scope.jitterBuff = true;
      scope.inputExtrap = true;
      scope.plc = true;
      scope.strictLifecycle = true;
      scope.worldWeatherSync = true;
      scope.worldPropsSync = true;
      scope.tireWearSync = false;
      scope.checkpointsUi = true;
      scope.aiTrafficSync = false;
      scope.aiTrafficPlc = true;
      scope.checkpointEvents = [];

      // Collapsible & Chat UI states
      scope.showDevSettings = false;
      scope.showChatLog = true;
      scope.chatInput = "";
      scope.chatLog = [];
      scope.lobbies = [];

      // Remote telemetry & tandem indicators
      scope.remoteTelemetry = {};
      scope.tandem = {
        dist: undefined,
        speedDiff: 0,
        angleDiff: 0,
        score: 0
      };

      scope.config = {
        ip: "127.0.0.1",
        port: 27015,
        clientPort: 0
      };

      scope.active = {
        ip: "",
        port: ""
      };

      // Network metrics
      scope.metrics = {
        ping: 0,
        jitter: 0,
        txRate: 0,
        rxRate: 0,
        packetLoss: 0,
        txKBs: 0,
        rxKBs: 0,
        hz: 240,
        pingHistory: [],
        pingMax: 1,
        sparklinePath: "",
        pendingAcks: 0,
        resendAttempts: 0,
        droppedReliablePackets: 0,
        activeNetVeh: 0,
        activeAiPuppets: 0,
        txAiKBs: 0,
        rxAiKBs: 0
      };

      // Build SVG sparkline path from ping history
      function buildSparkline(history, maxPing) {
        if (!history || history.length < 2) return "";
        var w = 200, h = 28;
        var step = w / (history.length - 1);
        var safeMax = maxPing > 0 ? maxPing : 1;
        var points = [];
        for (var i = 0; i < history.length; i++) {
          var x = (i * step).toFixed(1);
          var y = (h - (history[i] / safeMax) * (h - 2) - 1).toFixed(1);
          points.push(x + "," + y);
        }
        return "M" + points.join(" L");
      }

      // Update nickname in Lua
      scope.updateNickname = function() {
        if (!scope.nickname) return;
        var cleanName = scope.nickname.replace(/["\\\r\n]/g, "");
        bngApi.engineLua('extensions.lanMultiplayer.setNickname("' + cleanName + '")');
      };

      // Host connection
      scope.host = function() {
        var port = parseInt(scope.config.port, 10);
        if (isNaN(port)) port = 27015;
        bngApi.engineLua('extensions.lanMultiplayer.host(' + port + ')');
      };

      // Connect to host
      scope.connect = function() {
        if (!scope.config.ip) return;
        var ip = scope.config.ip.replace(/["\\\r\n]/g, "");
        var port = parseInt(scope.config.port, 10);
        if (isNaN(port)) port = 27015;
        var clientPort = parseInt(scope.config.clientPort, 10);
        if (isNaN(clientPort)) clientPort = 0;
        
        bngApi.engineLua('extensions.lanMultiplayer.connect("' + ip + '", ' + port + ', ' + clientPort + ')');
      };

      // Disconnect
      scope.disconnect = function() {
        bngApi.engineLua('extensions.lanMultiplayer.disconnect()');
      };

      // Toggle Ghost Mode
      scope.toggleGhostMode = function() {
        scope.ghostMode = !scope.ghostMode;
        bngApi.engineLua('extensions.lanMultiplayer.setGhostMode(' + scope.ghostMode + ')');
      };

      // Toggle Network Optimization
      scope.toggleNetworkOpt = function() {
        scope.networkOpt = !scope.networkOpt;
        bngApi.engineLua('extensions.lanMultiplayer.setNetworkOpt(' + scope.networkOpt + ')');
      };

      // Toggle Sound Sync
      scope.toggleSoundSync = function() {
        scope.soundSync = !scope.soundSync;
        bngApi.engineLua('extensions.lanMultiplayer.setSoundSync(' + scope.soundSync + ')');
      };

      // Toggle Wheel Sync
      scope.toggleWheelSync = function() {
        scope.wheelSync = !scope.wheelSync;
        bngApi.engineLua('extensions.lanMultiplayer.setWheelSync(' + scope.wheelSync + ')');
      };

      // Toggle Lights Sync
      scope.toggleLightsSync = function() {
        scope.lightsSync = !scope.lightsSync;
        bngApi.engineLua('extensions.lanMultiplayer.setLightsSync(' + scope.lightsSync + ')');
      };

      // Toggle Damage Sync
      scope.toggleDamageSync = function() {
        scope.damageSync = !scope.damageSync;
        bngApi.engineLua('extensions.lanMultiplayer.setDamageSync(' + scope.damageSync + ')');
      };

      // Toggle Tuning Sync
      scope.toggleTuningSync = function() {
        scope.tuningSync = !scope.tuningSync;
        bngApi.engineLua('extensions.lanMultiplayer.setTuningSync(' + scope.tuningSync + ')');
      };

      // Toggle Backfire Sync
      scope.toggleBackfireSync = function() {
        scope.backfireSync = !scope.backfireSync;
        bngApi.engineLua('extensions.lanMultiplayer.setBackfireSync(' + scope.backfireSync + ')');
      };

      // Toggle Recovery Sync
      scope.toggleRecoverySync = function() {
        scope.recoverySync = !scope.recoverySync;
        bngApi.engineLua('extensions.lanMultiplayer.setRecoverySync(' + scope.recoverySync + ')');
      };

      // Toggle Adaptive Hz
      scope.toggleAdaptiveHz = function() {
        scope.adaptiveHz = !scope.adaptiveHz;
        bngApi.engineLua('extensions.lanMultiplayer.setAdaptiveHz(' + scope.adaptiveHz + ')');
      };

      // Toggle Jitter Buffer
      scope.toggleJitterBuff = function() {
        scope.jitterBuff = !scope.jitterBuff;
        bngApi.engineLua('extensions.lanMultiplayer.setJitterBuffer(' + scope.jitterBuff + ')');
      };

      // Toggle Input Extrap
      scope.toggleInputExtrap = function() {
        scope.inputExtrap = !scope.inputExtrap;
        bngApi.engineLua('extensions.lanMultiplayer.setInputExtrap(' + scope.inputExtrap + ')');
      };

      // Toggle PLC
      scope.togglePLC = function() {
        scope.plc = !scope.plc;
        bngApi.engineLua('extensions.lanMultiplayer.setPLC(' + scope.plc + ')');
      };

      // Toggle Strict Lifecycle
      scope.toggleStrictLifecycle = function() {
        scope.strictLifecycle = !scope.strictLifecycle;
        bngApi.engineLua('extensions.lanMultiplayer.setStrictLifecycle(' + scope.strictLifecycle + ')');
      };

      scope.toggleWorldWeatherSync = function() {
        scope.worldWeatherSync = !scope.worldWeatherSync;
        bngApi.engineLua('extensions.lanMultiplayer.setWorldWeatherSync(' + scope.worldWeatherSync + ')');
      };

      scope.toggleWorldPropsSync = function() {
        scope.worldPropsSync = !scope.worldPropsSync;
        bngApi.engineLua('extensions.lanMultiplayer.setWorldPropsSync(' + scope.worldPropsSync + ')');
      };

      scope.toggleTireWearSync = function() {
        scope.tireWearSync = !scope.tireWearSync;
        bngApi.engineLua('extensions.lanMultiplayer.setTireWearSync(' + scope.tireWearSync + ')');
      };

      scope.toggleCheckpointsUi = function() {
        scope.checkpointsUi = !scope.checkpointsUi;
        bngApi.engineLua('extensions.lanMultiplayer.setCheckpointsUi(' + scope.checkpointsUi + ')');
      };

      scope.toggleAiTrafficSync = function() {
        scope.aiTrafficSync = !scope.aiTrafficSync;
        bngApi.engineLua('extensions.lanMultiplayer.setAiTrafficSync(' + scope.aiTrafficSync + ')');
      };

      scope.toggleAiTrafficPlc = function() {
        scope.aiTrafficPlc = !scope.aiTrafficPlc;
        bngApi.engineLua('extensions.lanMultiplayer.setAiTrafficPlc(' + scope.aiTrafficPlc + ')');
      };

      // Toggle Developer Settings
      scope.toggleDevSettings = function() {
        scope.showDevSettings = !scope.showDevSettings;
      };

      // Toggle Chat Log
      scope.toggleChatLog = function() {
        scope.showChatLog = !scope.showChatLog;
      };

      // Select discovered LAN server
      scope.selectLobby = function(lobby) {
        scope.config.ip = lobby.ip;
        scope.config.port = lobby.port;
      };

      // Send emote pill
      scope.sendEmote = function(text) {
        var cleanText = text.replace(/["\\\r\n]/g, "");
        bngApi.engineLua('extensions.lanMultiplayer.chatMessage("' + cleanText + '")');
      };

      // Send manual text chat message
      scope.sendChatMessage = function() {
        if (!scope.chatInput || scope.chatInput.trim() === "") return;
        var cleanMsg = scope.chatInput.replace(/["\\\r\n]/g, "");
        bngApi.engineLua('extensions.lanMultiplayer.chatMessage("' + cleanMsg + '")');
        scope.chatInput = "";
      };

      // Teleport to Friend
      scope.teleportToFriend = function() {
        bngApi.engineLua('extensions.lanMultiplayer.teleportToFriend()');
      };

      var isInitialized = false;

      // Handle status events from Lua engine
      scope.$on('lanMultiplayerStatus', function (event, data) {
        scope.$evalAsync(function () {
          scope.status = data.status;
          scope.role = data.role;
          
          scope.active.ip = data.activeIp || "";
          scope.active.port = data.activePort || "";

          if (data.nickname) {
            scope.nickname = data.nickname;
          }
          if (data.remoteNickname !== undefined) {
            scope.remoteNickname = data.remoteNickname;
          }
          if (data.ghostMode !== undefined) {
            scope.ghostMode = data.ghostMode;
          }
          if (data.networkOpt !== undefined) {
            scope.networkOpt = data.networkOpt;
          }
          if (data.soundSync !== undefined) {
            scope.soundSync = data.soundSync;
          }
          if (data.wheelSync !== undefined) {
            scope.wheelSync = data.wheelSync;
          }
          if (data.lightsSync !== undefined) {
            scope.lightsSync = data.lightsSync;
          }
          if (data.damageSync !== undefined) {
            scope.damageSync = data.damageSync;
          }
          if (data.tuningSync !== undefined) {
            scope.tuningSync = data.tuningSync;
          }
          if (data.backfireSync !== undefined) {
            scope.backfireSync = data.backfireSync;
          }
          if (data.recoverySync !== undefined) {
            scope.recoverySync = data.recoverySync;
          }
          if (data.adaptiveHz !== undefined) {
            scope.adaptiveHz = data.adaptiveHz;
          }
          if (data.jitterBuff !== undefined) {
            scope.jitterBuff = data.jitterBuff;
          }
          if (data.inputExtrap !== undefined) {
            scope.inputExtrap = data.inputExtrap;
          }
          if (data.plc !== undefined) {
            scope.plc = data.plc;
          }
          if (data.strictLifecycle !== undefined) {
            scope.strictLifecycle = data.strictLifecycle;
          }
          if (data.worldWeatherSync !== undefined) {
            scope.worldWeatherSync = data.worldWeatherSync;
          }
          if (data.worldPropsSync !== undefined) {
            scope.worldPropsSync = data.worldPropsSync;
          }
          if (data.tireWearSync !== undefined) {
            scope.tireWearSync = data.tireWearSync;
          }
          if (data.checkpointsUi !== undefined) {
            scope.checkpointsUi = data.checkpointsUi;
          }
          if (data.aiTrafficSync !== undefined) {
            scope.aiTrafficSync = data.aiTrafficSync;
          }
          if (data.aiTrafficPlc !== undefined) {
            scope.aiTrafficPlc = data.aiTrafficPlc;
          }

          scope.error = data.error || "";

          if (!isInitialized) {
            if (data.configIp) {
              scope.config.ip = data.configIp;
            }
            if (data.configPort) {
              scope.config.port = parseInt(data.configPort) || scope.config.port;
            }
            if (data.configClientPort !== undefined) {
              scope.config.clientPort = parseInt(data.configClientPort);
              if (isNaN(scope.config.clientPort)) scope.config.clientPort = 0;
            }
            isInitialized = true;
          }
        });
      });

      // Handle network metrics events from Lua engine
      scope.$on('lanMultiplayerMetrics', function (event, data) {
        scope.$evalAsync(function () {
          scope.metrics.ping = data.ping || 0;
          scope.metrics.jitter = data.jitter || 0;
          scope.metrics.txRate = data.txRate || 0;
          scope.metrics.rxRate = data.rxRate || 0;
          scope.metrics.packetLoss = data.packetLoss || 0;
          scope.metrics.txKBs = data.txKBs || 0;
          scope.metrics.rxKBs = data.rxKBs || 0;
          scope.metrics.hz = data.hz || 240;
          scope.metrics.pingHistory = data.pingHistory || [];
          scope.metrics.pingMax = data.pingMax || 1;
          scope.metrics.sparklinePath = buildSparkline(data.pingHistory, data.pingMax);
          scope.metrics.pendingAcks = data.pendingAcks || 0;
          scope.metrics.resendAttempts = data.resendAttempts || 0;
          scope.metrics.droppedReliablePackets = data.droppedReliablePackets || 0;
          scope.metrics.activeNetVeh = data.activeNetVeh || 0;
          scope.metrics.activeAiPuppets = data.activeAiPuppets || 0;
          scope.metrics.txAiKBs = data.txAiKBs || 0;
          scope.metrics.rxAiKBs = data.rxAiKBs || 0;
        });
      });

      // Handle lobbies auto-discovery
      scope.$on('lanMultiplayerLobby', function (event, lobbies) {
        scope.$evalAsync(function () {
          scope.lobbies = lobbies || [];
        });
      });

      // Handle remote vehicle telemetry
      scope.$on('lanMultiplayerRemoteTelemetry', function (event, telemetry) {
        scope.$evalAsync(function () {
          scope.remoteTelemetry = telemetry || {};
        });
      });

      // Handle tandem drift scorer updates
      scope.$on('lanMultiplayerTandemUpdate', function (event, data) {
        scope.$evalAsync(function () {
          scope.tandem.dist = data.dist;
          scope.tandem.speedDiff = data.speedDiff || 0;
          scope.tandem.angleDiff = data.angleDiff || 0;
          scope.tandem.score = data.score || 0;
        });
      });

      // Handle chat messages
      scope.$on('lanMultiplayerCheckpoint', function (event, data) {
        scope.$evalAsync(function () {
          if (data.events) {
            scope.checkpointEvents = data.events;
          }
        });
      });

      scope.$on('lanMultiplayerChat', function (event, chat) {
        scope.$evalAsync(function () {
          scope.chatLog.push({
            sender: chat.sender || "System",
            text: chat.text || ""
          });
          // Keep chat log capped at 50 messages to prevent memory leak
          if (scope.chatLog.length > 50) {
            scope.chatLog.shift();
          }
        });
      });

      // Request status immediately upon app load
      bngApi.engineLua('extensions.lanMultiplayer.requestStatus()');
    }
  };
}]);
