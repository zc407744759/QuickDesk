// Remote Desktop Window - Independent window for remote desktop connections
import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QuickDesk 1.0

import "../component"
import "../quickdeskcomponent"

Window {
    id: remoteWindow
    width: 1280
    height: 720
    visible: true
    title: qsTr("QuickDesk - Remote Desktop")
    
    // Properties
    property var clientManager: null
    property string localDeviceId: ""  // Local device ID — used to detect self-connection
    property alias connectionModel: connectionModelObj  // C++ model for incremental updates
    property int currentTabIndex: 0
    property bool hasAutoResized: false  // Only auto-resize once on first frame
    property bool showVideoStats: false  // Toggle video stats overlay
    property var closingConnections: ({})  // Guard against re-entrant closeConnection calls
    property bool emergencyStopActive: false

    // Multi-monitor: display list per device. Map: deviceId -> { displays: [], activeIndex: 0 }
    property var displayListMap: ({})
    property int displayListVersion: 0  // Increment to notify changes

    // Virtual displays per device. Map: deviceId -> [{index, width, height, refreshRate}]
    property var virtualDisplayMap: ({})
    property int virtualDisplayVersion: 0
    
    // C++ ConnectionListModel — only affected delegates are created/destroyed
    ConnectionListModel {
        id: connectionModelObj
    }
    
    // Performance stats stored separately to avoid triggering model rebuild
    // Map: deviceId -> { frameWidth, frameHeight, frameRate, ping,
    //   originalWidth, originalHeight, captureMs, encodeMs, networkDelayMs,
    //   decodeMs, paintMs, totalLatencyMs, inputRoundtripMs, bandwidthKbps,
    //   packetRate, codec, frameQuality, encodedRectWidth, encodedRectHeight }
    property var performanceStatsMap: ({})
    property int statsVersion: 0  // Increment to notify changes
    
    // Get performance stats for a connection
    function getPerformanceStats(deviceId) {
        return performanceStatsMap[deviceId] || {
            frameWidth: 0, frameHeight: 0, frameRate: 0, ping: 0,
            originalWidth: 0, originalHeight: 0,
            captureMs: 0, encodeMs: 0, networkDelayMs: 0, decodeMs: 0, paintMs: 0,
            totalLatencyMs: 0, inputRoundtripMs: 0,
            bandwidthKbps: 0, packetRate: 0,
            codec: "", frameQuality: -1,
            encodedRectWidth: 0, encodedRectHeight: 0
        }
    }
    
    // Update performance stats without modifying connections model
    function updatePerformanceStats(deviceId, width, height, fps, ping) {
        var stats = performanceStatsMap[deviceId]
        
        // Handle video size update
        if (width !== undefined && height !== undefined && width > 0 && height > 0) {
            // Ensure fps is non-negative and round to integer for comparison
            if (fps !== undefined) {
                fps = Math.max(0, Math.round(fps))
            }
            
            // Check if there's any actual change
            if (stats && stats.frameWidth === width && stats.frameHeight === height && 
                (fps === undefined || stats.frameRate === fps)) {
                // No video change, but might need to update ping
                if (ping === undefined) {
                    return  // Nothing to update
                }
            }
            
            // Record original resolution on first valid frame
            var originalWidth = stats ? stats.originalWidth : 0
            var originalHeight = stats ? stats.originalHeight : 0
            
            if (!stats || (stats.originalWidth === 0 && width > 0 && height > 0)) {
                originalWidth = width
                originalHeight = height
                console.log("✓ Recorded original resolution for", deviceId, ":", width + "x" + height)
            }
            
            // Merge into existing stats to preserve route data etc.
            var newStatsMap = Object.assign({}, performanceStatsMap)
            newStatsMap[deviceId] = Object.assign({}, stats || {}, {
                frameWidth: width,
                frameHeight: height,
                frameRate: fps !== undefined ? fps : (stats ? stats.frameRate : 0),
                ping: ping !== undefined ? ping : (stats ? stats.ping : 0),
                originalWidth: originalWidth,
                originalHeight: originalHeight
            })
            performanceStatsMap = newStatsMap
            
            // Only increment version if width or height changed (affects layout)
            if (!stats || stats.frameWidth !== width || stats.frameHeight !== height) {
                statsVersion++
            }
        } 
        // Handle ping-only update
        else if (ping !== undefined && stats) {
            var newStatsMap = Object.assign({}, performanceStatsMap)
            newStatsMap[deviceId] = Object.assign({}, stats, {ping: ping})
            performanceStatsMap = newStatsMap
        }
    }
    
    // Add connection to this window
    function addConnection(deviceId) {
        var existingIdx = connectionModel.indexOf(deviceId)
        if (existingIdx >= 0) {
            console.log("Connection already exists in window:", deviceId)
            currentTabIndex = existingIdx
            return
        }
        
        connectionModel.addConnection(deviceId)
        initializeConnectionState(deviceId)
        
        // Initialize performance stats
        var newStatsMap = Object.assign({}, performanceStatsMap)
        newStatsMap[deviceId] = {
            frameWidth: 0, frameHeight: 0, frameRate: 0, ping: 0,
            originalWidth: 0, originalHeight: 0,
            captureMs: 0, encodeMs: 0, networkDelayMs: 0, decodeMs: 0, paintMs: 0,
            totalLatencyMs: 0, inputRoundtripMs: 0,
            bandwidthKbps: 0, packetRate: 0,
            codec: "", frameQuality: -1,
            encodedRectWidth: 0, encodedRectHeight: 0
        }
        performanceStatsMap = newStatsMap
        
        currentTabIndex = connectionModel.count - 1
        console.log("Added connection to remote window:", deviceId, "Total tabs:", connectionModel.count)
    }

    function initializeConnectionState(deviceId) {
        if (!clientManager) return

        var connectedDeviceIds = clientManager.connectedDeviceIds
        var connectionExists = false
        for (var i = 0; i < connectedDeviceIds.length; i++) {
            if (connectedDeviceIds[i] === deviceId) {
                connectionExists = true
                break
            }
        }

        if (!connectionExists) {
            return
        }

        var rtcState = clientManager.getConnectionRtcState(deviceId)
        var state = "connecting"
        if (rtcState === RtcStatus.Connected) {
            state = "connected"
        } else if (rtcState === RtcStatus.Disconnected) {
            state = "disconnected"
        } else if (rtcState === RtcStatus.Failed) {
            state = "failed"
        }

        connectionModel.updateState(deviceId, state)
    }
    
    // Close connection and remove tab (unified function for both scenarios)
    // needDisconnect=true when user initiates close; false when reacting to an already-disconnected signal
    function closeConnection(index, needDisconnect) {
        if (needDisconnect === undefined) needDisconnect = true

        if (index < 0 || index >= connectionModel.count) {
            return
        }
        
        var tabDeviceId = connectionModel.deviceIdAt(index)
        
        // Prevent re-entrant calls (disconnectFromHost may trigger onConnectionStateChanged synchronously)
        if (closingConnections[tabDeviceId]) {
            return
        }
        closingConnections[tabDeviceId] = true
        
        console.log("Closing connection:", tabDeviceId, "at index:", index, "needDisconnect:", needDisconnect)
        
        // Send the disconnect before removing the last tab. removeConnection()
        // can close this window, which makes post-cleanup disconnects unreliable.
        if (needDisconnect && clientManager) {
            clientManager.disconnectFromHost(tabDeviceId)
        }

        removeConnection(index)
        
        delete closingConnections[tabDeviceId]
    }
    
    // Remove connection from this window (internal helper)
    function removeConnection(index) {
        if (index < 0 || index >= connectionModel.count) return
        
        var tabDeviceId = connectionModel.deviceIdAt(index)
        
        // Remove from performance stats map
        var newStatsMap = Object.assign({}, performanceStatsMap)
        delete newStatsMap[tabDeviceId]
        performanceStatsMap = newStatsMap
        
        // Remove from model — only destroys this one delegate
        connectionModel.removeConnection(index)
        
        // Update current tab index
        if (currentTabIndex >= connectionModel.count) {
            currentTabIndex = Math.max(0, connectionModel.count - 1)
        }
        
        // Close window if no connections left
        if (connectionModel.count === 0) {
            remoteWindow.close()
        }
        
        console.log("Removed connection from remote window:", tabDeviceId, "Remaining tabs:", connectionModel.count)
    }
    
    // Clean up all connections when window closes
    onClosing: function(close) {
        console.log("RemoteWindow closing, disconnecting all connections")
        var deviceIds = []
        for (var i = 0; i < connectionModel.count; i++) {
            deviceIds.push(connectionModel.deviceIdAt(i))
        }
        for (var j = 0; j < deviceIds.length; j++) {
            if (!clientManager) continue
            console.log("Disconnecting:", deviceIds[j])
            clientManager.disconnectFromHost(deviceIds[j])
        }
        connectionModel.clear()
    }
    
    // Core resize logic — resize window to best fit the given remote desktop resolution
    // Can be called manually at any time (e.g. from toolbar "Fit Window" button)
    function resizeToFit(fw, fh) {
        if (fw <= 0 || fh <= 0) return

        var scr = remoteWindow.screen
        if (!scr) {
            console.warn("resizeToFit: screen not available")
            return false
        }

        // Use this screen's available geometry, not desktopAvailableWidth/
        // desktopAvailableHeight. The latter represent the whole virtual
        // desktop and can make the window larger than a 1080p monitor in a
        // mixed-resolution multi-monitor setup.
        var available = scr.availableGeometry
        if (!available || available.width <= 0 || available.height <= 0) {
            // Keep a safe fallback for platforms that do not expose an
            // available geometry through QML.
            available = {
                x: scr.virtualX,
                y: scr.virtualY,
                width: scr.width,
                height: scr.height
            }
        }

        // Leave an additional outer margin so native window decorations,
        // including the title bar, remain reachable.
        var outerMargin = 16
        var maxWidth = Math.max(1, available.width - outerMargin * 2)
        var maxHeight = Math.max(1, available.height - outerMargin * 2)

        // Account for tab bar height
        var tabBarH = tabBar.height > 0 ? tabBar.height : 36
        var contentMaxHeight = maxHeight - tabBarH

        // Calculate scale factor (never upscale)
        var scale = Math.min(maxWidth / fw, contentMaxHeight / fh, 1.0)

        var newWidth  = Math.round(fw * scale)
        var newHeight = Math.round(fh * scale) + tabBarH

        // Center on screen
        remoteWindow.width  = newWidth
        remoteWindow.height = newHeight
        remoteWindow.x = available.x + Math.round((available.width - newWidth) / 2)
        remoteWindow.y = available.y + Math.round((available.height - newHeight) / 2)

        console.log("Resized window to", newWidth + "x" + newHeight,
                     "for remote desktop", fw + "x" + fh,
                     "(scale:", scale.toFixed(3) + ")",
                     "screen:", scr.width + "x" + scr.height,
                     "available:", available.width + "x" + available.height)
        return true
    }

    // Auto-resize window to best fit the remote desktop resolution (called once on first frame)
    // Triggered from onStatsVersionChanged (at window level, not inside Repeater delegate)
    function autoResizeToFit(fw, fh) {
        console.log("autoResizeToFit called:", fw + "x" + fh,
                     "hasAutoResized:", hasAutoResized,
                     "screen:", remoteWindow.screen ? "valid" : "null")

        if (fw <= 0 || fh <= 0) return
        if (hasAutoResized) return

        if (!remoteWindow.screen) {
            // Screen not ready — retry via Timer
            console.log("autoResizeToFit: screen not ready, scheduling retry")
            retryResizeTimer.pendingWidth = fw
            retryResizeTimer.pendingHeight = fh
            retryResizeTimer.retryCount = 0
            retryResizeTimer.start()
            return
        }

        // Mark AFTER screen check so retries work
        hasAutoResized = true
        resizeToFit(fw, fh)
    }

    // When frame dimensions change (statsVersion incremented), try auto-resize
    // Using Qt.callLater ensures execution on a clean call stack,
    // avoiding issues with nested signal handler / delegate destruction races.
    onStatsVersionChanged: {
        if (hasAutoResized) return
        if (connectionModel.count === 0) return

        var tabDeviceId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count
                     ? connectionModel.deviceIdAt(currentTabIndex) : ""
        if (!tabDeviceId) return

        var s = getPerformanceStats(tabDeviceId)
        if (s && s.frameWidth > 0 && s.frameHeight > 0) {
            var w = s.frameWidth
            var h = s.frameHeight
            Qt.callLater(function() {
                autoResizeToFit(w, h)
            })
        }
    }

    // Update connection state
    function updateConnectionState(deviceId, state, ping) {
        // Update state in model (only emits dataChanged for the affected row)
        if (state !== "") {
            connectionModel.updateState(deviceId, state)
        }
        
        // Update ping in performance stats map (doesn't trigger model rebuild)
        if (ping !== undefined) {
            updatePerformanceStats(deviceId, undefined, undefined, undefined, ping)
        }
    }
    
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        
        // Tab Bar
        RemoteTabBar {
            id: tabBar
            Layout.fillWidth: true
            connectionModel: remoteWindow.connectionModel
            currentIndex: remoteWindow.currentTabIndex
            performanceStatsMap: remoteWindow.performanceStatsMap
            statsVersion: remoteWindow.statsVersion
            
            onTabClicked: function(index) {
                remoteWindow.currentTabIndex = index
            }
            
            onTabCloseRequested: function(index) {
                remoteWindow.closeConnection(index)
            }
            
            onNewTabRequested: {
                // TODO: Show quick connect dialog
                console.log("New tab requested")
            }
        }
        
        // Remote Desktop View Stack
        StackLayout {
            id: desktopStack
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: remoteWindow.currentTabIndex
            
            Repeater {
                model: connectionModel
                
                Item {
                    id: delegateItem
                    required property int index
                    required property string deviceId
                    required property string name
                    required property string state
                    
                    // Detect self-connection: remote deviceId matches local deviceId
                    readonly property bool isSelfConnection: remoteWindow.localDeviceId !== "" && delegateItem.deviceId === remoteWindow.localDeviceId
                    
                    // Remote desktop video view (ONLY video, no overlay UI)
                    RemoteDesktopView {
                        id: desktopView
                        anchors.fill: parent
                        deviceId: delegateItem.deviceId
                        clientManager: remoteWindow.clientManager
                        active: delegateItem.index === remoteWindow.currentTabIndex
                        inputEnabled: !delegateItem.isSelfConnection  // Disable input for self-connection
                        
                        onFilesDropped: function(urls) {
                            for (var i = 0; i < urls.length; i++) {
                                remoteWindow.addLocalFile(urls[i])
                            }
                            transferDialog.show()
                        }

                        // Monitor video size changes (frameRate and ping updated from PerformanceTracker)
                        onFrameWidthChanged: {
                            if (frameWidth > 0 && frameHeight > 0) {
                                var devId = delegateItem.deviceId
                                var stats = remoteWindow.getPerformanceStats(devId)
                                remoteWindow.updatePerformanceStats(devId, frameWidth, frameHeight, stats.frameRate, stats.ping)
                            }
                        }
                        onFrameHeightChanged: {
                            if (frameWidth > 0 && frameHeight > 0) {
                                var devId = delegateItem.deviceId
                                var stats = remoteWindow.getPerformanceStats(devId)
                                remoteWindow.updatePerformanceStats(devId, frameWidth, frameHeight, stats.frameRate, stats.ping)
                            }
                        }
                    }
                }
            }
        }
    }
        
    Item {
        anchors.fill: parent
        anchors.topMargin: tabBar.height  // Offset by tab bar height        
        
        // Single floating button bound to current active connection
        FloatingToolButton {
            x: parent.width - width - Theme.spacingXLarge
            y: Theme.spacingXLarge
            z: 1000
            visible: connectionModel.count > 0
            
            deviceId: currentTabIndex >= 0 && currentTabIndex < connectionModel.count 
                ? connectionModel.deviceIdAt(currentTabIndex) 
                : ""
            clientManager: remoteWindow.clientManager
            supportsSendAttentionSequence: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count 
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var stats = devId ? remoteWindow.getPerformanceStats(devId) : null
                return stats ? (stats.supportsSendAttentionSequence || false) : false
            }
            supportsLockWorkstation: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count 
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var stats = devId ? remoteWindow.getPerformanceStats(devId) : null
                return stats ? (stats.supportsLockWorkstation || false) : false
            }
            supportsFileTransfer: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count 
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var stats = devId ? remoteWindow.getPerformanceStats(devId) : null
                return stats ? (stats.supportsFileTransfer || false) : false
            }
            supportsPrivacyScreen: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count 
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var stats = devId ? remoteWindow.getPerformanceStats(devId) : null
                return stats ? (stats.supportsPrivacyScreen || false) : false
            }
            supportsVirtualDisplay: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count 
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var stats = devId ? remoteWindow.getPerformanceStats(devId) : null
                return stats ? (stats.supportsVirtualDisplay || false) : false
            }
            virtualDisplays: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var _ = remoteWindow.virtualDisplayVersion
                return devId ? (remoteWindow.virtualDisplayMap[devId] || []) : []
            }
            emergencyStopActive: remoteWindow.emergencyStopActive
            displayList: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var _ = remoteWindow.displayListVersion  // force re-evaluate on change
                var info = devId ? remoteWindow.displayListMap[devId] : null
                return info ? info.displays : []
            }
            activeDisplayIndex: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                var _ = remoteWindow.displayListVersion
                var info = devId ? remoteWindow.displayListMap[devId] : null
                return info ? info.activeIndex : -1
            }
            videoInfo: {
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count 
                    ? connectionModel.deviceIdAt(currentTabIndex) 
                    : ""
                return devId ? remoteWindow.getPerformanceStats(devId) : null
            }
            desktopView: {
                // Find the current desktop view
                if (remoteWindow.currentTabIndex >= 0) {
                    var stackItem = desktopStack.children[remoteWindow.currentTabIndex]
                    return stackItem ? stackItem.children[0] : null
                }
                return null
            }
            
            onDisconnectRequested: function(deviceId) {
                console.log("FloatingToolButton disconnect requested for:", deviceId)
                var idx = connectionModel.indexOf(deviceId)
                if (idx >= 0) {
                    remoteWindow.closeConnection(idx)
                }
            }

            onEmergencyStopRequested: {
                if (remoteWindow.emergencyStopActive) {
                    mainController.deactivateEmergencyStop()
                    remoteWindow.emergencyStopActive = false
                    toast.show(qsTr("Emergency stop deactivated"))
                } else {
                    mainController.activateEmergencyStop("user_manual")
                    remoteWindow.emergencyStopActive = true
                    toast.show(qsTr("Emergency stop activated - all AI operations halted"))
                }
            }
            
            onFitToRemoteDesktopRequested: {
                // Get current tab's frame dimensions and resize window
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                if (!devId) return

                var s = remoteWindow.getPerformanceStats(devId)
                if (s && s.frameWidth > 0 && s.frameHeight > 0) {
                    console.log("Manual fit window to remote desktop:", s.frameWidth + "x" + s.frameHeight)
                    remoteWindow.resizeToFit(s.frameWidth, s.frameHeight)
                }
            }
            
            onToggleVideoStats: {
                remoteWindow.showVideoStats = !remoteWindow.showVideoStats
            }
            
            onShowToast: function(message, toastType) {
                toast.show(message, toastType)
            }

            activeTransferCount: remoteWindow.activeTransferCount

            onUploadFileRequested: {
                transferDialog.show()
                fileDialog.open()
            }

            onDownloadFileRequested: {
                transferDialog.show()
                remoteWindow.startRemoteDownload()
            }

            onShowTransferPanelRequested: {
                transferDialog.show()
            }
        }
        
        // Video Stats Overlay — semi-transparent panel with detailed stats
        VideoStatsOverlay {
            id: videoStatsOverlay
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: Theme.spacingMedium
            z: 999
            visible: remoteWindow.showVideoStats && connectionModel.count > 0
            
            stats: {
                // Force re-evaluation when statsVersion changes
                var _version = remoteWindow.statsVersion
                var devId = currentTabIndex >= 0 && currentTabIndex < connectionModel.count
                    ? connectionModel.deviceIdAt(currentTabIndex) : ""
                return devId ? remoteWindow.getPerformanceStats(devId) : null
            }
        }
    }
    
    // Monitor connection state changes
    Connections {
        target: remoteWindow.clientManager
        
        function onConnectionStateChanged(deviceId, state, hostInfo) {
            console.log("Remote window: connection state changed:", deviceId, state)

            if (!remoteWindow || !remoteWindow.closingConnections) return

            // Skip if this connection is already being closed
            if (remoteWindow.closingConnections[deviceId]) {
                return
            }
            
            // Update connection state
            remoteWindow.updateConnectionState(deviceId, state, 0)
            
            // Auto-close tab when connection is disconnected or failed
            // needDisconnect=false: the connection is already gone, just remove the tab
            if (state === "disconnected" || state === "failed") {
                var deviceIdCopy = deviceId
                Qt.callLater(function() {
                    var idx = connectionModel.indexOf(deviceIdCopy)
                    if (idx >= 0) {
                        console.log("Auto-closing tab for", state, "connection:", deviceIdCopy, "at index:", idx)
                        remoteWindow.closeConnection(idx, false)
                    }
                })
            }
        }
    }
    
    // Fallback: clean up tab when connection is removed from ClientManager
    // This catches cases where connectionStateChanged might not fire (e.g. disconnectAll, process crash)
    Connections {
        target: remoteWindow.clientManager
        
        function onConnectionRemoved(deviceId) {
            if (!remoteWindow || !remoteWindow.closingConnections) return
            if (remoteWindow.closingConnections[deviceId]) {
                return
            }
            
            var deviceIdCopy = deviceId
            Qt.callLater(function() {
                var idx = connectionModel.indexOf(deviceIdCopy)
                if (idx >= 0) {
                    console.log("Fallback: removing orphan tab for removed connection:", deviceIdCopy)
                    remoteWindow.closeConnection(idx, false)
                }
            })
        }
    }
    
    // Monitor performance stats updates (detailed stats from C++ PerformanceTracker)
    Connections {
        target: remoteWindow.clientManager
        
        function onPerformanceStatsUpdated(deviceId, detailedStats) {
            var totalLatencyMs = detailedStats.totalLatencyMs || 0
            var frameRate = detailedStats.frameRate || 0
            
            // Update connection latency value (for tab bar display)
            remoteWindow.updateConnectionState(deviceId, "", totalLatencyMs)
            
            // Update frameRate and merge detailed stats
            var existing = remoteWindow.getPerformanceStats(deviceId)
            if (existing && existing.frameWidth > 0 && existing.frameHeight > 0) {
                remoteWindow.updatePerformanceStats(deviceId,
                    existing.frameWidth, existing.frameHeight, frameRate, totalLatencyMs)
            }
            
            // Merge detailed timing/codec stats into performanceStatsMap
            var current = remoteWindow.performanceStatsMap[deviceId]
            if (current) {
                var newStatsMap = Object.assign({}, remoteWindow.performanceStatsMap)
                newStatsMap[deviceId] = Object.assign({}, current, {
                    captureMs:         detailedStats.captureMs || 0,
                    encodeMs:          detailedStats.encodeMs || 0,
                    networkDelayMs:    detailedStats.networkDelayMs || 0,
                    decodeMs:          detailedStats.decodeMs || 0,
                    paintMs:           detailedStats.paintMs || 0,
                    totalLatencyMs:    totalLatencyMs,
                    inputRoundtripMs:  detailedStats.inputRoundtripMs || 0,
                    bandwidthKbps:     detailedStats.bandwidthKbps || 0,
                    packetRate:        detailedStats.packetRate || 0,
                    codec:             detailedStats.codec || "",
                    frameQuality:      detailedStats.frameQuality !== undefined ? detailedStats.frameQuality : -1,
                    encodedRectWidth:  detailedStats.encodedRectWidth || 0,
                    encodedRectHeight: detailedStats.encodedRectHeight || 0
                })
                remoteWindow.performanceStatsMap = newStatsMap
            }
        }
    }

    // Monitor host capabilities negotiation
    Connections {
        target: remoteWindow.clientManager

        function onHostCapabilitiesChanged(deviceId, supportsSendAttentionSequence, supportsLockWorkstation, supportsFileTransfer, supportsPrivacyScreen, supportsVirtualDisplay) {
            var current = remoteWindow.performanceStatsMap[deviceId] || {}
            var newStatsMap = Object.assign({}, remoteWindow.performanceStatsMap)
            newStatsMap[deviceId] = Object.assign({}, current, {
                supportsSendAttentionSequence: supportsSendAttentionSequence,
                supportsLockWorkstation: supportsLockWorkstation,
                supportsFileTransfer: supportsFileTransfer,
                supportsPrivacyScreen: supportsPrivacyScreen,
                supportsVirtualDisplay: supportsVirtualDisplay
            })
            remoteWindow.performanceStatsMap = newStatsMap
        }
    }

    // Monitor virtual display state changes
    Connections {
        target: remoteWindow.clientManager

        function onVirtualDisplayStateChanged(deviceId, state) {
            var type = state.type || ""
            if (type === "created" || type === "removed" || type === "removedAll") {
                // Re-query to get the latest list
                remoteWindow.clientManager.queryVirtualDisplays(deviceId)
            } else if (type === "state") {
                var displays = state.displays || []
                var newMap = Object.assign({}, remoteWindow.virtualDisplayMap)
                newMap[deviceId] = displays
                remoteWindow.virtualDisplayMap = newMap
                remoteWindow.virtualDisplayVersion++
            } else if (type === "error") {
                console.warn("Virtual display error:", state.message)
            }
        }
    }

    // Monitor display list changes (multi-monitor)
    Connections {
        target: remoteWindow.clientManager

        function onDisplayListChanged(deviceId, displays, activeDisplayIndex) {
            var newMap = Object.assign({}, remoteWindow.displayListMap)
            newMap[deviceId] = {
                displays: displays,
                activeIndex: activeDisplayIndex
            }
            remoteWindow.displayListMap = newMap
            remoteWindow.displayListVersion++
            console.log("Display list updated for", deviceId,
                        ": displays=", displays.length,
                        ", active=", activeDisplayIndex)
        }
    }

    // Monitor ICE route changes
    Connections {
        target: remoteWindow.clientManager

        function onRouteChanged(deviceId, routeInfo) {
            var current = remoteWindow.performanceStatsMap[deviceId]
            if (current) {
                var newStatsMap = Object.assign({}, remoteWindow.performanceStatsMap)
                newStatsMap[deviceId] = Object.assign({}, current, {
                    routeType: routeInfo.routeType || "",
                    transportProtocol: routeInfo.transportProtocol || "",
                    localCandidateType: routeInfo.localCandidateType || "",
                    remoteCandidateType: routeInfo.remoteCandidateType || "",
                    localAddress: routeInfo.localAddress || "",
                    remoteAddress: routeInfo.remoteAddress || "",
                    localCandidates: routeInfo.localCandidates || [],
                    remoteCandidates: routeInfo.remoteCandidates || []
                })
                remoteWindow.performanceStatsMap = newStatsMap
            }
        }
    }

    // File upload dialog (supports multiple file selection)
    FileDialog {
        id: fileDialog
        title: qsTr("Select Files to Upload")
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            transferDialog.show()
            for (var i = 0; i < selectedFiles.length; i++) {
                remoteWindow.addLocalFile(selectedFiles[i])
            }
        }
    }

    ListModel {
        id: localFileModel
    }

    ListModel {
        id: remoteFileModel
    }

    // File transfer data model
    ListModel {
        id: transferModel
    }

    property string localCurrentPath: mainController.ftpManager
        ? mainController.ftpManager.lastLocalDirectory() : ""
    property string remoteCurrentPath: ""
    property int selectedLocalFileIndex: -1
    property int selectedRemoteFileIndex: -1
    property var selectedLocalPaths: ({})
    property var selectedRemotePaths: ({})
    property int selectedLocalCount: 0
    property int selectedRemoteCount: 0

    property int activeTransferCount: {
        var count = 0
        for (var i = 0; i < transferModel.count; i++) {
            var s = transferModel.get(i).status
            if (s === "uploading" || s === "downloading") count++
        }
        return count
    }

    function findTransferIndex(transferId) {
        for (var i = 0; i < transferModel.count; i++) {
            if (transferModel.get(i).transferId === transferId) return i
        }
        return -1
    }

    function findTransferByFilename(filename) {
        for (var i = transferModel.count - 1; i >= 0; i--) {
            var item = transferModel.get(i)
            if (item.filename === filename && item.transferId === "") return i
        }
        return -1
    }

    function formatBytes(bytes) {
        var value = Number(bytes || 0)
        var units = ["B", "KB", "MB", "GB", "TB"]
        var unit = 0
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024
            unit++
        }
        return (unit === 0 ? Math.round(value) : value.toFixed(value >= 10 ? 1 : 2)) + " " + units[unit]
    }

    function formatSpeed(bytesPerSecond) {
        return remoteWindow.formatBytes(bytesPerSecond || 0) + "/s"
    }

    function pathSelected(map, path) {
        return !!map[path || ""]
    }

    function clearLocalSelection() {
        remoteWindow.selectedLocalPaths = ({})
        remoteWindow.selectedLocalCount = 0
        remoteWindow.selectedLocalFileIndex = -1
    }

    function clearRemoteSelection() {
        remoteWindow.selectedRemotePaths = ({})
        remoteWindow.selectedRemoteCount = 0
        remoteWindow.selectedRemoteFileIndex = -1
    }

    function setSelectionPath(kind, path, selected) {
        var source = kind === "local" ? remoteWindow.selectedLocalPaths : remoteWindow.selectedRemotePaths
        var next = {}
        var count = 0
        for (var key in source) {
            if (source[key]) next[key] = true
        }
        if (selected) next[path] = true
        else delete next[path]
        for (var selectedKey in next) {
            if (next[selectedKey]) count++
        }
        if (kind === "local") {
            remoteWindow.selectedLocalPaths = next
            remoteWindow.selectedLocalCount = count
        } else {
            remoteWindow.selectedRemotePaths = next
            remoteWindow.selectedRemoteCount = count
        }
    }

    function selectOnly(kind, index, path) {
        if (kind === "local") {
            remoteWindow.clearLocalSelection()
            remoteWindow.selectedLocalFileIndex = index
        } else {
            remoteWindow.clearRemoteSelection()
            remoteWindow.selectedRemoteFileIndex = index
        }
        remoteWindow.setSelectionPath(kind, path, true)
    }

    function toggleSelection(kind, index, path) {
        if (kind === "local") remoteWindow.selectedLocalFileIndex = index
        else remoteWindow.selectedRemoteFileIndex = index
        var map = kind === "local" ? remoteWindow.selectedLocalPaths : remoteWindow.selectedRemotePaths
        remoteWindow.setSelectionPath(kind, path, !remoteWindow.pathSelected(map, path))
    }

    function selectRange(kind, fromIndex, toIndex) {
        var model = kind === "local" ? localFileModel : remoteFileModel
        if (model.count === 0) return
        var start = Math.max(0, Math.min(fromIndex < 0 ? toIndex : fromIndex, toIndex))
        var end = Math.min(model.count - 1, Math.max(fromIndex < 0 ? toIndex : fromIndex, toIndex))
        if (kind === "local") remoteWindow.clearLocalSelection()
        else remoteWindow.clearRemoteSelection()
        for (var i = start; i <= end; i++) {
            remoteWindow.setSelectionPath(kind, model.get(i).path, true)
        }
        if (kind === "local") remoteWindow.selectedLocalFileIndex = toIndex
        else remoteWindow.selectedRemoteFileIndex = toIndex
    }

    function handleLocalSelection(index, path, modifiers) {
        if (modifiers & Qt.ShiftModifier) remoteWindow.selectRange("local", remoteWindow.selectedLocalFileIndex, index)
        else if (modifiers & (Qt.ControlModifier | Qt.MetaModifier)) remoteWindow.toggleSelection("local", index, path)
        else remoteWindow.selectOnly("local", index, path)
    }

    function handleRemoteSelection(index, path, modifiers) {
        if (modifiers & Qt.ShiftModifier) remoteWindow.selectRange("remote", remoteWindow.selectedRemoteFileIndex, index)
        else if (modifiers & (Qt.ControlModifier | Qt.MetaModifier)) remoteWindow.toggleSelection("remote", index, path)
        else remoteWindow.selectOnly("remote", index, path)
    }

    function hasSelectedLocalFiles() {
        for (var i = 0; i < localFileModel.count; i++) {
            var item = localFileModel.get(i)
            if (!item.isDir && remoteWindow.pathSelected(remoteWindow.selectedLocalPaths, item.path)) return true
        }
        return false
    }

    function hasSelectedRemoteFiles() {
        for (var i = 0; i < remoteFileModel.count; i++) {
            var item = remoteFileModel.get(i)
            if (!item.isDir && remoteWindow.pathSelected(remoteWindow.selectedRemotePaths, item.path)) return true
        }
        return false
    }

    function filenameFromUrl(fileUrl) {
        var raw = fileUrl ? fileUrl.toString() : ""
        var parts = raw.split("/")
        return decodeURIComponent(parts.length > 0 ? parts[parts.length - 1] : raw)
    }

    function localPathFromFileUrl(fileUrl) {
        var raw = decodeURIComponent(fileUrl ? fileUrl.toString() : "")
        if (raw.indexOf("file://") !== 0) return raw
        var path = raw.substring(7)
        if (path.length > 2 && path.charAt(0) === "/" && path.charAt(2) === ":") {
            path = path.substring(1)
        }
        return path
    }

    function localFileExists(fileUrl) {
        var url = fileUrl ? fileUrl.toString() : ""
        for (var i = 0; i < localFileModel.count; i++) {
            if (localFileModel.get(i).url === url) return true
        }
        return false
    }

    function addLocalFile(fileUrl) {
        var url = fileUrl ? fileUrl.toString() : ""
        if (url === "" || remoteWindow.localFileExists(fileUrl)) return
        var path = remoteWindow.localPathFromFileUrl(fileUrl)
        localFileModel.append({
            url: url,
            filename: remoteWindow.filenameFromUrl(fileUrl),
            name: remoteWindow.filenameFromUrl(fileUrl),
            path: path,
            isDir: false,
            size: 0
        })
        remoteWindow.selectOnly("local", localFileModel.count - 1, path)
    }

    function setLocalEntries(entries) {
        localFileModel.clear()
        remoteWindow.clearLocalSelection()
        for (var i = 0; i < entries.length; i++) {
            var item = entries[i]
            localFileModel.append({
                url: remoteWindow.fileUrlFromLocalPath(item.path || ""),
                filename: item.name || "",
                name: item.name || "",
                path: item.path || "",
                isDir: item.isDir || false,
                size: item.size || 0
            })
        }
    }

    function refreshLocalDirectory(path) {
        if (!mainController.ftpManager) return
        remoteWindow.localCurrentPath = path || remoteWindow.localCurrentPath
        mainController.ftpManager.saveLastLocalDirectory(remoteWindow.localCurrentPath)
        remoteWindow.setLocalEntries(mainController.ftpManager.listLocalDirectory(remoteWindow.localCurrentPath))
    }

    function refreshRemoteDirectory(path) {
        var devId = remoteWindow.currentDeviceId()
        if (!devId || !mainController.ftpManager) return
        var targetPath = path === undefined ? remoteWindow.remoteCurrentPath : path
        if (targetPath === "") targetPath = mainController.ftpManager.lastRemoteDirectory(devId)
        mainController.ftpManager.listRemoteDirectory(devId, targetPath)
    }

    function fileUrlFromLocalPath(filePath) {
        if (!filePath) return ""
        if (filePath.indexOf("file:") === 0) return filePath
        var normalized = filePath.replace(/\\/g, "/")
        if (normalized.charAt(0) === "/") return "file://" + normalized
        return "file:///" + normalized
    }

    function addLocalDownloadedFile(filePath, filename) {
        var url = remoteWindow.fileUrlFromLocalPath(filePath)
        if (url === "" || remoteWindow.localFileExists(url)) return
        localFileModel.append({
            url: url,
            filename: filename || remoteWindow.filenameFromUrl(url),
            name: filename || remoteWindow.filenameFromUrl(url),
            path: filePath,
            isDir: false,
            size: 0
        })
        remoteWindow.selectOnly("local", localFileModel.count - 1, filePath)
    }

    function currentDeviceId() {
        return currentTabIndex >= 0 && currentTabIndex < connectionModel.count
            ? connectionModel.deviceIdAt(currentTabIndex) : ""
    }

    function startUploadAndTrack(deviceId, fileUrl) {
        if (!deviceId || !remoteWindow.clientManager) return false
        if (!remoteWindow.clientManager.startFileUpload(deviceId, fileUrl)) {
            return false
        }

        transferModel.append({
            transferId: "",
            deviceId: deviceId,
            filename: remoteWindow.filenameFromUrl(fileUrl),
            progress: 0,
            status: "uploading",
            errorMessage: "",
            direction: "upload",
            savePath: ""
        })
        return true
    }

    function uploadSelectedLocalFile() {
        var devId = remoteWindow.currentDeviceId()
        if (!devId || !mainController.ftpManager) return
        for (var i = 0; i < localFileModel.count; i++) {
            var item = localFileModel.get(i)
            if (item.isDir || !remoteWindow.pathSelected(remoteWindow.selectedLocalPaths, item.path)) continue
            mainController.ftpManager.uploadFile(devId, remoteWindow.fileUrlFromLocalPath(item.path),
                                                 remoteWindow.remoteCurrentPath)
        }
        transferDialog.show()
    }

    function startRemoteDownload() {
        var devId = remoteWindow.currentDeviceId()
        if (!devId || !mainController.ftpManager) return
        for (var i = 0; i < remoteFileModel.count; i++) {
            var item = remoteFileModel.get(i)
            if (item.isDir || !remoteWindow.pathSelected(remoteWindow.selectedRemotePaths, item.path)) continue
            mainController.ftpManager.downloadFile(devId, item.path, remoteWindow.localCurrentPath)
        }
        transferDialog.show()
    }

    // File transfer event handlers
    Connections {
        target: remoteWindow.clientManager

        function onFileTransferProgress(deviceId, transferId, filename, bytesSent, totalBytes) {
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx < 0) {
                idx = remoteWindow.findTransferByFilename(filename)
                if (idx >= 0) {
                    transferModel.setProperty(idx, "transferId", transferId)
                } else {
                    transferModel.append({
                        transferId: transferId,
                        deviceId: deviceId,
                        filename: filename,
                        progress: 0,
                        status: "uploading",
                        errorMessage: "",
                        direction: "upload",
                        savePath: ""
                    })
                    idx = transferModel.count - 1
                }
            }
            var pct = totalBytes > 0 ? bytesSent / totalBytes : 0
            transferModel.setProperty(idx, "progress", pct)
        }

        function onFileTransferComplete(deviceId, transferId, filename) {
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx < 0) idx = remoteWindow.findTransferByFilename(filename)
            if (idx >= 0) {
                transferModel.setProperty(idx, "status", "complete")
                transferModel.setProperty(idx, "progress", 1)
                if (transferModel.get(idx).transferId === "")
                    transferModel.setProperty(idx, "transferId", transferId)
            }
            toast.show(qsTr("Upload complete: %1").arg(filename), QDToast.Type.Success)
        }

        function onFileTransferError(deviceId, transferId, errorMessage) {
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx < 0) {
                for (var i = transferModel.count - 1; i >= 0; i--) {
                    if (transferModel.get(i).status === "uploading" && transferModel.get(i).transferId === "") {
                        idx = i
                        break
                    }
                }
            }
            if (idx >= 0) {
                transferModel.setProperty(idx, "status", "error")
                transferModel.setProperty(idx, "errorMessage", errorMessage)
                if (transferId && transferModel.get(idx).transferId === "")
                    transferModel.setProperty(idx, "transferId", transferId)
            }
            toast.show(qsTr("Upload failed: %1").arg(errorMessage), QDToast.Type.Error)
        }

        function onFileDownloadStarted(deviceId, transferId, filename, totalBytes) {
            transferModel.append({
                transferId: transferId,
                deviceId: deviceId,
                filename: filename,
                progress: 0,
                status: "downloading",
                errorMessage: "",
                direction: "download",
                savePath: ""
            })
            transferDialog.show()
        }

        function onFileDownloadProgress(deviceId, transferId, filename, bytesReceived, totalBytes) {
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx >= 0) {
                var pct = totalBytes > 0 ? bytesReceived / totalBytes : 0
                transferModel.setProperty(idx, "progress", pct)
            }
        }

        function onFileDownloadComplete(deviceId, transferId, filename, savePath) {
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx >= 0) {
                transferModel.setProperty(idx, "status", "complete")
                transferModel.setProperty(idx, "progress", 1)
                transferModel.setProperty(idx, "savePath", savePath)
            }
            remoteWindow.addLocalDownloadedFile(savePath, filename)
            toast.show(qsTr("Download complete: %1").arg(filename), QDToast.Type.Success)
        }

        function onFileDownloadError(deviceId, transferId, errorMessage) {
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx >= 0) {
                transferModel.setProperty(idx, "status", "error")
                transferModel.setProperty(idx, "errorMessage", errorMessage)
            }
            toast.show(qsTr("Download failed: %1").arg(errorMessage), QDToast.Type.Error)
        }
    }

    Connections {
        target: mainController.ftpManager

        function onRemoteDirectoryListed(deviceId, path, entries) {
            if (deviceId !== remoteWindow.currentDeviceId()) return
            remoteWindow.remoteCurrentPath = path
            if (mainController.ftpManager) {
                mainController.ftpManager.saveLastRemoteDirectory(deviceId, path)
            }
            remoteFileModel.clear()
            remoteWindow.clearRemoteSelection()
            for (var i = 0; i < entries.length; i++) {
                var item = entries[i]
                remoteFileModel.append({
                    name: item.name || "",
                    filename: item.name || "",
                    path: item.path || "",
                    isDir: item.isDir || false,
                    size: item.size || 0
                })
            }
        }

        function onClientConnected(deviceId) {
            if (deviceId !== remoteWindow.currentDeviceId()) return
            var targetPath = remoteWindow.remoteCurrentPath
            if (targetPath === "" && mainController.ftpManager) {
                targetPath = mainController.ftpManager.lastRemoteDirectory(deviceId)
            }
            remoteWindow.refreshRemoteDirectory(targetPath)
        }

        function onTransferProgress(deviceId, transferId, direction, transferredBytes, totalBytes, filename) {
            if (deviceId !== remoteWindow.currentDeviceId()) return
            var now = Date.now()
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx < 0) {
                transferModel.append({
                    transferId: transferId,
                    deviceId: deviceId,
                    filename: filename || direction,
                    progress: 0,
                    status: direction === "download" ? "downloading" : "uploading",
                    errorMessage: "",
                    direction: direction,
                    savePath: "",
                    transferredBytes: transferredBytes,
                    totalBytes: totalBytes,
                    lastBytes: transferredBytes,
                    lastUpdatedAt: now,
                    speedBytesPerSecond: 0
                })
                idx = transferModel.count - 1
            }
            var item = transferModel.get(idx)
            if (filename && item.filename !== filename) {
                transferModel.setProperty(idx, "filename", filename)
            }
            var elapsed = Math.max(0.001, (now - (item.lastUpdatedAt || now)) / 1000)
            var speed = Math.max(0, (transferredBytes - (item.lastBytes || 0)) / elapsed)
            transferModel.setProperty(idx, "progress", totalBytes > 0 ? transferredBytes / totalBytes : 0)
            transferModel.setProperty(idx, "transferredBytes", transferredBytes)
            transferModel.setProperty(idx, "totalBytes", totalBytes)
            transferModel.setProperty(idx, "lastBytes", transferredBytes)
            transferModel.setProperty(idx, "lastUpdatedAt", now)
            transferModel.setProperty(idx, "speedBytesPerSecond", speed)
        }

        function onTransferComplete(deviceId, transferId, direction, localPath, remotePath) {
            if (deviceId !== remoteWindow.currentDeviceId()) return
            var idx = remoteWindow.findTransferIndex(transferId)
            if (idx >= 0) {
                transferModel.setProperty(idx, "status", "complete")
                transferModel.setProperty(idx, "progress", 1)
                transferModel.setProperty(idx, "speedBytesPerSecond", 0)
                transferModel.setProperty(idx, "filename", direction === "download"
                    ? remoteWindow.filenameFromUrl(remoteWindow.fileUrlFromLocalPath(localPath))
                    : remoteWindow.filenameFromUrl(remoteWindow.fileUrlFromLocalPath(remotePath)))
                transferModel.setProperty(idx, "savePath", localPath || "")
            }
            remoteWindow.refreshLocalDirectory(remoteWindow.localCurrentPath)
            remoteWindow.refreshRemoteDirectory(remoteWindow.remoteCurrentPath)
            toast.show(direction === "download" ? qsTr("Download complete") : qsTr("Upload complete"),
                       QDToast.Type.Success)
        }

        function onErrorOccurred(deviceId, code, message) {
            if (deviceId !== "" && deviceId !== remoteWindow.currentDeviceId()) return
            toast.show(message, QDToast.Type.Error)
        }
    }

    component FtpFilePane: Rectangle {
        id: ftpPane
        property string paneTitle: ""
        property string paneSubtitle: ""
        property string currentPath: ""
        property var fileModel
        property var selectedPaths: ({})
        property bool remoteSide: false
        signal pathAccepted(string path)
        signal parentRequested()
        signal homeRequested()
        signal refreshRequested()
        signal itemClicked(int index, string path, int modifiers)
        signal itemDoubleClicked(int index, string path, bool isDir)

        color: Theme.surfaceVariant
        radius: Theme.radiusSmall
        border.width: Theme.borderWidthThin
        border.color: Theme.border

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingSmall
            spacing: Theme.spacingSmall

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingSmall

                Text {
                    Layout.fillWidth: true
                    text: ftpPane.paneTitle
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: Theme.text
                    elide: Text.ElideRight
                }

                Text {
                    text: ftpPane.paneSubtitle
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.textSecondary
                    elide: Text.ElideRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXSmall

                QDIconButton {
                    iconSource: FluentIconGlyph.backGlyph
                    buttonSize: QDIconButton.Size.Small
                    buttonStyle: QDIconButton.Style.Standard
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Parent directory")
                    onClicked: ftpPane.parentRequested()
                }

                QDIconButton {
                    iconSource: FluentIconGlyph.homeGlyph
                    buttonSize: QDIconButton.Size.Small
                    buttonStyle: QDIconButton.Style.Standard
                    visible: !ftpPane.remoteSide
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Home")
                    onClicked: ftpPane.homeRequested()
                }

                QDIconButton {
                    iconSource: FluentIconGlyph.syncGlyph
                    buttonSize: QDIconButton.Size.Small
                    buttonStyle: QDIconButton.Style.Standard
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Refresh")
                    onClicked: ftpPane.refreshRequested()
                }

                QDTextField {
                    id: pathField
                    Layout.fillWidth: true
                    text: ftpPane.currentPath
                    prefixIcon: FluentIconGlyph.folderOpenGlyph
                    font.pixelSize: Theme.fontSizeSmall
                    selectByMouse: true
                    onAccepted: ftpPane.pathAccepted(text)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                color: Theme.surface
                radius: Theme.radiusSmall
                border.width: Theme.borderWidthThin
                border.color: Theme.border

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingMedium
                    anchors.rightMargin: Theme.spacingMedium
                    spacing: Theme.spacingMedium

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Name")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }

                    Text {
                        Layout.preferredWidth: 86
                        text: qsTr("Size")
                        horizontalAlignment: Text.AlignRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }

                    Text {
                        Layout.preferredWidth: 72
                        text: qsTr("Type")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }
                }
            }

            ListView {
                id: ftpListView
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: ftpPane.fileModel
                clip: true
                spacing: 1
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: fileRow
                    width: ftpListView.width
                    height: 34
                    radius: 2
                    readonly property bool rowSelected: remoteWindow.pathSelected(ftpPane.selectedPaths, model.path)
                    color: rowSelected ? Qt.rgba(0.0, 0.48, 1.0, 0.22)
                        : (rowHover.hovered ? Theme.surfaceHover : "transparent")
                    border.width: rowSelected ? Theme.borderWidthThin : 0
                    border.color: Theme.primary

                    HoverHandler { id: rowHover }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onClicked: function(mouse) {
                            ftpPane.itemClicked(index, model.path, mouse.modifiers)
                        }
                        onDoubleClicked: {
                            ftpPane.itemDoubleClicked(index, model.path, model.isDir)
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingMedium
                        anchors.rightMargin: Theme.spacingMedium
                        spacing: Theme.spacingMedium

                        Text {
                            text: model.isDir ? FluentIconGlyph.folderGlyph : FluentIconGlyph.documentGlyph
                            font.family: "Segoe Fluent Icons"
                            font.pixelSize: Theme.iconSizeSmall
                            color: model.isDir ? Theme.primary : Theme.textSecondary
                        }

                        Text {
                            Layout.fillWidth: true
                            text: model.name || model.filename
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.text
                            elide: Text.ElideMiddle
                        }

                        Text {
                            Layout.preferredWidth: 86
                            text: model.isDir ? "" : remoteWindow.formatBytes(model.size)
                            horizontalAlignment: Text.AlignRight
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.textSecondary
                        }

                        Text {
                            Layout.preferredWidth: 72
                            text: model.isDir ? qsTr("Folder") : qsTr("File")
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.textSecondary
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            QDEmptyState {
                visible: ftpPane.fileModel && ftpPane.fileModel.count === 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                iconSource: ftpPane.remoteSide ? FluentIconGlyph.syncFolderGlyph : FluentIconGlyph.folderOpenGlyph
                title: ftpPane.remoteSide ? qsTr("Remote folder is empty") : qsTr("Local folder is empty")
                description: ftpPane.remoteSide ? qsTr("Refresh or check the remote file channel") : qsTr("Choose another local directory")
            }
        }
    }

    component TransferQueuePanel: Rectangle {
        id: queuePanel

        color: Theme.surfaceVariant
        radius: Theme.radiusSmall
        border.width: Theme.borderWidthThin
        border.color: Theme.border

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingSmall
            spacing: Theme.spacingSmall

            RowLayout {
                Layout.fillWidth: true

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Transfer Queue")
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: Theme.text
                }

                Text {
                    text: remoteWindow.activeTransferCount > 0
                        ? qsTr("%1 active").arg(remoteWindow.activeTransferCount)
                        : qsTr("%1 items").arg(transferModel.count)
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.textSecondary
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                color: Theme.surface
                radius: Theme.radiusSmall

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingMedium
                    anchors.rightMargin: Theme.spacingMedium
                    spacing: Theme.spacingMedium

                    Text {
                        Layout.preferredWidth: 86
                        text: qsTr("Direction")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("File")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }

                    Text {
                        Layout.preferredWidth: 170
                        text: qsTr("Progress")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }

                    Text {
                        Layout.preferredWidth: 92
                        text: qsTr("Speed")
                        horizontalAlignment: Text.AlignRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }

                    Text {
                        Layout.preferredWidth: 92
                        text: qsTr("Status")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.textSecondary
                    }
                }
            }

            ListView {
                id: queueListView
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: transferModel
                clip: true
                spacing: 1

                delegate: Rectangle {
                    width: queueListView.width
                    height: 34
                    radius: 2
                    color: queueHover.hovered ? Theme.surfaceHover : "transparent"

                    HoverHandler { id: queueHover }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingMedium
                        anchors.rightMargin: Theme.spacingMedium
                        spacing: Theme.spacingMedium

                        Text {
                            Layout.preferredWidth: 86
                            text: model.direction === "download" ? qsTr("Remote -> Local") : qsTr("Local -> Remote")
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.text
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            text: model.filename
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            color: model.status === "error" ? Theme.error : Theme.text
                            elide: Text.ElideMiddle
                        }

                        RowLayout {
                            Layout.preferredWidth: 170
                            spacing: Theme.spacingSmall

                            QDProgressBar {
                                Layout.fillWidth: true
                                value: model.progress || 0
                                progressColor: model.status === "error" ? Theme.error
                                    : (model.status === "complete" ? Theme.success : Theme.primary)
                            }

                            Text {
                                Layout.preferredWidth: 38
                                text: Math.round((model.progress || 0) * 100) + "%"
                                horizontalAlignment: Text.AlignRight
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.textSecondary
                            }
                        }

                        Text {
                            Layout.preferredWidth: 92
                            text: model.status === "complete" ? "" : remoteWindow.formatSpeed(model.speedBytesPerSecond || 0)
                            horizontalAlignment: Text.AlignRight
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.textSecondary
                        }

                        Text {
                            Layout.preferredWidth: 92
                            text: model.status === "error"
                                ? qsTr("Failed")
                                : (model.status === "complete" ? qsTr("Done") : qsTr("Transferring"))
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            color: model.status === "error" ? Theme.error
                                : (model.status === "complete" ? Theme.success : Theme.textSecondary)
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            QDEmptyState {
                visible: transferModel.count === 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                iconSource: FluentIconGlyph.syncGlyph
                title: qsTr("No transfers")
                description: qsTr("Select files and copy them between panes")
            }
        }
    }

    QDDialog {
        id: transferDialog
        title: qsTr("File Transfer") + (remoteWindow.activeTransferCount > 0
            ? " (" + remoteWindow.activeTransferCount + ")" : "")
        dialogWidth: Math.min(remoteWindow.width - Theme.spacingXLarge * 2, 1120)
        dialogHeight: Math.min(remoteWindow.height - Theme.spacingXLarge * 2, 720)
        closeOnOverlay: true
        onShowingChanged: {
            if (showing) {
                var devId = remoteWindow.currentDeviceId()
                if (remoteWindow.remoteCurrentPath === "" && devId && mainController.ftpManager) {
                    remoteWindow.remoteCurrentPath = mainController.ftpManager.lastRemoteDirectory(devId)
                }
                remoteWindow.refreshLocalDirectory(remoteWindow.localCurrentPath)
                remoteWindow.refreshRemoteDirectory(remoteWindow.remoteCurrentPath)
            }
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: Theme.spacingSmall

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Theme.spacingSmall

                FtpFilePane {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 360
                    paneTitle: qsTr("Local site")
                    paneSubtitle: remoteWindow.selectedLocalCount > 0
                        ? qsTr("%1 selected").arg(remoteWindow.selectedLocalCount)
                        : qsTr("%1 items").arg(localFileModel.count)
                    currentPath: remoteWindow.localCurrentPath
                    fileModel: localFileModel
                    selectedPaths: remoteWindow.selectedLocalPaths
                    remoteSide: false
                    onPathAccepted: function(path) { remoteWindow.refreshLocalDirectory(path) }
                    onParentRequested: remoteWindow.refreshLocalDirectory(
                        mainController.ftpManager.parentDirectory(remoteWindow.localCurrentPath))
                    onHomeRequested: remoteWindow.refreshLocalDirectory(mainController.ftpManager.homeDirectory())
                    onRefreshRequested: remoteWindow.refreshLocalDirectory(remoteWindow.localCurrentPath)
                    onItemClicked: function(index, path, modifiers) {
                        remoteWindow.handleLocalSelection(index, path, modifiers)
                    }
                    onItemDoubleClicked: function(index, path, isDir) {
                        remoteWindow.selectOnly("local", index, path)
                        if (isDir) remoteWindow.refreshLocalDirectory(path)
                        else remoteWindow.uploadSelectedLocalFile()
                    }
                }

                ColumnLayout {
                    Layout.preferredWidth: 56
                    Layout.fillHeight: true
                    spacing: Theme.spacingSmall

                    Item { Layout.fillHeight: true }

                    QDIconButton {
                        iconSource: FluentIconGlyph.forwardGlyph
                        buttonSize: QDIconButton.Size.Large
                        buttonStyle: QDIconButton.Style.Accent
                        enabled: remoteWindow.hasSelectedLocalFiles()
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Upload selected files")
                        onClicked: remoteWindow.uploadSelectedLocalFile()
                    }

                    QDIconButton {
                        iconSource: FluentIconGlyph.backGlyph
                        buttonSize: QDIconButton.Size.Large
                        buttonStyle: QDIconButton.Style.Standard
                        enabled: remoteWindow.hasSelectedRemoteFiles()
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Download selected files")
                        onClicked: remoteWindow.startRemoteDownload()
                    }

                    Item { Layout.fillHeight: true }
                }

                FtpFilePane {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 360
                    paneTitle: qsTr("Remote site")
                    paneSubtitle: remoteWindow.selectedRemoteCount > 0
                        ? qsTr("%1 selected").arg(remoteWindow.selectedRemoteCount)
                        : qsTr("%1 items").arg(remoteFileModel.count)
                    currentPath: remoteWindow.remoteCurrentPath
                    fileModel: remoteFileModel
                    selectedPaths: remoteWindow.selectedRemotePaths
                    remoteSide: true
                    onPathAccepted: function(path) { remoteWindow.refreshRemoteDirectory(path) }
                    onParentRequested: remoteWindow.refreshRemoteDirectory(
                        mainController.ftpManager.parentDirectory(remoteWindow.remoteCurrentPath))
                    onRefreshRequested: remoteWindow.refreshRemoteDirectory(remoteWindow.remoteCurrentPath)
                    onItemClicked: function(index, path, modifiers) {
                        remoteWindow.handleRemoteSelection(index, path, modifiers)
                    }
                    onItemDoubleClicked: function(index, path, isDir) {
                        remoteWindow.selectOnly("remote", index, path)
                        if (isDir) remoteWindow.refreshRemoteDirectory(path)
                        else remoteWindow.startRemoteDownload()
                    }
                }
            }

            TransferQueuePanel {
                Layout.fillWidth: true
                Layout.preferredHeight: 170
                Layout.minimumHeight: 132
            }
        }
    }

    // Trust confirmation dialog
    TrustConfirmationDialog {
        id: trustDialog
        onApproved: function(confirmationId, reason) {
            mainController.resolveConfirmation(confirmationId, true, reason)
        }
        onRejected: function(confirmationId, reason) {
            mainController.resolveConfirmation(confirmationId, false, reason)
        }
    }

    Connections {
        target: mainController
        function onTrustConfirmationRequested(confirmationId, deviceId, toolName,
                                               argumentsJson, riskLevel, reasons, timeoutSecs) {
            var parsedArgs = {}
            try { parsedArgs = JSON.parse(argumentsJson) } catch(e) {}
            trustDialog.showConfirmation(confirmationId, deviceId, toolName,
                                          parsedArgs, riskLevel, reasons, timeoutSecs)
        }
        function onTrustEmergencyStopActivated(reason) {
            remoteWindow.emergencyStopActive = true
            toast.show(qsTr("Emergency stop activated: ") + reason)
        }
        function onTrustEmergencyStopDeactivated() {
            remoteWindow.emergencyStopActive = false
            toast.show(qsTr("Emergency stop deactivated"))
        }
    }

    // Toast for notifications
    QDToast {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 50
        z: 9999
    }
}
