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
        sparklinePath: ""
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
        });
      });

      // Request status immediately upon app load
      bngApi.engineLua('extensions.lanMultiplayer.requestStatus()');
    }
  };
}]);
