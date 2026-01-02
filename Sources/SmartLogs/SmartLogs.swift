import Foundation

public enum LogBodyType: String {
    case chart = "chart"
    case image = "image"
    case object = "object"
}

public struct LogChartData {
    let x: [Float]
    let y: [Float]
    
    public init(x: [Float], y: [Float]) {
        self.x = x
        self.y = y
    }
}

public actor SmartLogs: NSObject, Sendable, URLSessionWebSocketDelegate {
    // Params
    let origin: String
    let serverURL: URL?

    // WebSocket
    private let socket: URLSessionWebSocketTask?
    private let session: URLSession = .init(configuration: .default)

    // Heartbeat
    private var heartbeatTask: Task<Void, Never>?

    // Queue
    private var messageQueue: [String] = []

    // States
    private var isReady: Bool = false
    private var isSendingQueueStarted: Bool = false
    private var willDisconnect: Bool = false

    // Init
    public init(origin: String = "", serverURL: String = "") {
        // Origin
        if origin != "" {
            self.origin = origin
        } else if let envOrigin = ProcessInfo.processInfo.environment["LOGS_ORIGIN"] {
            self.origin = envOrigin
        } else {
            self.origin = "client"
        }

        // Server URL
        if serverURL.isEmpty {
            self.serverURL = URL(string: serverURL)
        } else if let envServerURL = ProcessInfo.processInfo.environment["LOGS_SERVER_URL"] {
            self.serverURL = URL(string: envServerURL)
        } else {
            self.serverURL = URL(string: "ws://localhost:5175")
        }

        // Create the socket
        if let url = self.serverURL {
            socket = session.webSocketTask(with: url)
        } else {
            socket = nil
        }

        heartbeatTask = nil

        super.init()

        // Connect
        if let socket = socket {
            socket.delegate = self

            _listen()
            connect()
        }
    }

    // Listen for messages
    private func _handleMessage(_ message: URLSessionWebSocketTask.Message) {
        do {
            var msg: [String: Sendable]?
            switch message {
            case let .string(text):
                msg = try JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as? [String: any Sendable]
            case let .data(data):
                msg = try JSONSerialization.jsonObject(with: data) as? [String: any Sendable]
            @unknown default: break
            }

            guard let msg = msg else { return }
            if let action = msg["action"] as? String {
                switch action {
                case "requestTimeSync":
                    Task { await self.syncTime() }
                default:
                    break
                }
            }

        } catch {
            print("Error decoding message from server: ", message)
        }
    }

    private nonisolated func _listen() {
        Task {
            while let socket = self.socket {
                do {
                    // This 'await' waits for the next message without blocking the thread
                    let message = try await socket.receive()
                    await self._handleMessage(message)
                } catch {
                    print("Connection lost: \(error)")
                    break
                }
            }
        }
    }

    // Connection
    // -- Connect
    public nonisolated func connect() {
        Task {
            await self._connect()
        }
    }

    private func _connect() {
        guard let socket = socket else { return }
        socket.resume()
    }

    // -- Reconnect
    public nonisolated func reconnect() {
        Task {
            await self._reconnect()
        }
    }

    private func _reconnect() {
        guard let socket = socket else { return }
        socket.cancel()
        socket.resume()
    }

    // -- Disconnect
    public nonisolated func disconnect() {
        Task {
            await self._disconnect()
        }
    }

    private func _disconnect() async {
        try? await Task.sleep(for: .seconds(2))
        if messageQueue.isEmpty {
            isReady = false
            if let socket = socket {
                socket.cancel()
            }
            if let heartbeatTask = heartbeatTask {
                heartbeatTask.cancel()
            }
        } else {
            willDisconnect = true
        }
    }

    // Delegate
    // -- Open
    public nonisolated func urlSession(
        _: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?
    ) {
        Task {
            await self.syncTime()
            await self.startHeartbeat()
            await self.startSendingQueue()
        }
    }

    // -- Close
    public nonisolated func urlSession(
        _: URLSession, webSocketTask _: URLSessionWebSocketTask,
        didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?
    ) {
        disconnect()
    }

    // Sync time
    func syncTime() async {
        // Guard the socket
        guard let socket = socket else {
            return
        }

        do {
            let payload: [String: Any] = [
                "action": "timeSync",
                "payload": [
                    "clientTime": String(getPreciseTime()),
                ],
            ]

            let payloadEncoded = try JSONSerialization.data(withJSONObject: payload, options: [])
            let payloadString = String(data: payloadEncoded, encoding: .utf8) ?? "{}"
            try await socket.send(.string(payloadString))

            // Flip the state
            isReady = true
        } catch {
            return
        }
    }

    // Start heartbeat
    private func startHeartbeat() {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self.heartbeatFunction()
            }
        }
    }

    private func heartbeatFunction() {
        do {
            let payload: [String: Sendable] = [
                "action": "heartbeat",
                "payload": [String: Sendable](),
            ]

            let payloadEncoded = try JSONSerialization.data(withJSONObject: payload, options: [])
            Task {
                self.send(message: String(data: payloadEncoded, encoding: .utf8)!)
            }
        } catch {
            _reconnect()
        }
    }

    // Start Queue
    private func startSendingQueue() {
        // Check if connection is ready
        if isReady == false { return }
        // Check if another queue is already running
        if isSendingQueueStarted { return }

        // Guard the socket
        guard let socket = socket else { return }

        // Flip the state
        isSendingQueueStarted = true
        defer { self.isSendingQueueStarted = false }

        Task {
            while self.messageQueue.isEmpty == false {
                do {
                    if let message = self.messageQueue.first {
                        try await socket.send(.string(message))

                        // Remove message from queue
                        self.messageQueue.removeFirst()
                    }
                } catch {
                    self._reconnect()
                }

                // Delay
                try? await Task.sleep(for: .milliseconds(1))
            }

            // If will disconnect
            if self.willDisconnect == true {
                Task { await self._disconnect() }
            }
        }
    }

    // Send function
    private func send(message: String) {
        // Add message to queue
        messageQueue.append(message)

        // Start the queue if already finished
        startSendingQueue()
    }
}

// Abstractions
public extension SmartLogs {
    // Create Workflow
    nonisolated func createWorkflow(
        workflowId: String, title: String, description: String = ""
    ) {
        let workflow: [String: String] = [
            "workflowId": workflowId,
            "title": title,
            "description": description,
        ]
        do {
            let payload: [String: Any] = [
                "action": "createWorkflow",
                "payload": workflow,
            ]

            let payloadEncoded = try JSONSerialization.data(withJSONObject: payload, options: [])
            Task {
                await self.send(message: String(data: payloadEncoded, encoding: .utf8)!)
            }
        } catch {
            print(error)
        }
    }

    nonisolated func workflow(workflowId: String, title: String, description: String = "") {
        createWorkflow(workflowId: workflowId, title: title, description: description)
    }

    // Log
    nonisolated func log<T: Any>(
        workflowId: String, message: String, body: T, bodyType: LogBodyType = .object, order: Int = -1
    ) {
        if let body = body as? Codable,
           let bodyData = try? JSONEncoder().encode(body),
           let bodyDict = try? JSONSerialization.jsonObject(with: bodyData, options: .fragmentsAllowed)
        {
            log(workflowId: workflowId, message: message, body: bodyDict, bodyType: bodyType, order: order)
        } else {
            log(workflowId: workflowId, message: message, bodyType: bodyType, order: order)
        }
    }

    nonisolated func log(workflowId: String, message: String, body: [String: Any] = [:], bodyType: LogBodyType = .object, order: Int = -1) {
        do {
            let logObject: [String: Any] = [
                "workflowId": workflowId,
                "message": message,
                "body": body,
                "bodyType": bodyType.rawValue,
                "timestamp": Date().ISO8601Format(),
                "clientTime": String(getPreciseTime()),
                "order": order,
                "origin": origin,
            ]

            let payload: [String: Any] = [
                "action": "log",
                "payload": logObject,
            ]

            let payloadEncoded = try JSONSerialization.data(withJSONObject: payload, options: [])
            Task {
                await self.send(message: String(data: payloadEncoded, encoding: .utf8)!)
            }
        } catch {
            print(error)
        }
    }

    // Chart
    nonisolated func chart(workflowId: String, message: String, data: LogChartData, title: String = "", order: Int = -1) {
        self.logChart(workflowId: workflowId, message: message, data: data, title: title, order: order)
    }
    nonisolated func logChart(workflowId: String, message: String, data: LogChartData, title: String = "", order: Int = -1) {
        var body: [String: Any] = [
            "x": data.x,
            "y": data.y,
        ]
        if title != "" {
            body["title"] = title
        }
        print(body)
        // self.log(workflowId: workflowId, message: message, body: body, bodyType: .chart, order: order)
    }

    // Image
    nonisolated func image(workflowId: String, message: String, image: String, order: Int = -1) {
        print("IMGGG")
        self.logImage(workflowId: workflowId, message: message, image: image, order: order)
    }
    nonisolated func logImage(workflowId: String, message: String, image: String, order: Int = -1) {
        let body: [String: Any] = [
            "image": image,
        ]
        self.log(workflowId: workflowId, message: message, body: body, bodyType: .image, order: order)
    }

    // End Workflow
    nonisolated func endWorkflow(workflowId: String, order: Int = -1) {
        do {
            let payload: [String: Any] = [
                "action": "endWorkflow",
                "payload": [
                    "workflowId": workflowId,
                    "timestamp": Date().ISO8601Format(),
                    "clientTime": String(getPreciseTime()),
                    "order": order,
                    "origin": origin,
                ],
            ]

            let payloadEncoded = try JSONSerialization.data(withJSONObject: payload, options: [])
            Task {
                await self.send(message: String(data: payloadEncoded, encoding: .utf8)!)
            }
        } catch {
            print(error)
        }
    }
}
