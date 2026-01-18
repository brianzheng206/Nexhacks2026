//
//  MeshViewerView.swift
//  RoomSensor
//
//  3D Mesh Viewer using SceneKit
//

import SwiftUI
import SceneKit
import ModelIO
import Combine

struct MeshViewerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var meshViewModel = MeshViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Live 3D Mesh")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    meshViewModel.resetCamera()
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset View")
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.2))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            .padding()
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.4, green: 0.49, blue: 0.92), Color(red: 0.46, green: 0.29, blue: 0.64)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            
            // Status bar
            VStack(spacing: 4) {
                HStack {
                    Text(meshViewModel.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                if meshViewModel.triangleCount > 0 {
                    HStack(spacing: 16) {
                        Text("Triangles: \(meshViewModel.triangleCount.formatted())")
                            .font(.caption)
                            .foregroundColor(Color(red: 0.42, green: 0.61, blue: 0.82))
                        
                        Text("Vertices: \(meshViewModel.vertexCount.formatted())")
                            .font(.caption)
                            .foregroundColor(Color(red: 0.42, green: 0.61, blue: 0.82))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(red: 0.16, green: 0.16, blue: 0.16))
            
            // 3D Scene View
            SceneKitView(meshViewModel: meshViewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.1, green: 0.1, blue: 0.18))
            
            // Controls hint
            VStack(alignment: .leading, spacing: 4) {
                Text("Controls:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Label("Drag: Rotate", systemImage: "hand.draw")
                    Label("Pinch: Zoom", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    Label("Two-finger drag: Pan", systemImage: "arrow.up.and.down")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(red: 0.16, green: 0.16, blue: 0.16))
        }
        .onAppear {
            if let laptopIP = appState.laptopIP, let token = appState.token {
                meshViewModel.startPolling(laptopIP: laptopIP, token: token)
            }
        }
        .onDisappear {
            meshViewModel.stopPolling()
        }
        .onChange(of: appState.laptopIP) { newIP in
            if let ip = newIP, let token = appState.token {
                meshViewModel.startPolling(laptopIP: ip, token: token)
            }
        }
        .onChange(of: appState.token) { newToken in
            if let token = newToken, let laptopIP = appState.laptopIP {
                meshViewModel.startPolling(laptopIP: laptopIP, token: token)
            }
        }
    }
}

// MARK: - SceneKit View Wrapper

struct SceneKitView: UIViewRepresentable {
    @ObservedObject var meshViewModel: MeshViewModel
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.scene = meshViewModel.scene
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        sceneView.antialiasingMode = .multisampling4X
        
        // Store reference for camera reset
        meshViewModel.sceneView = sceneView
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        // Update scene if needed
        uiView.scene = meshViewModel.scene
    }
}

// MARK: - Mesh View Model

class MeshViewModel: ObservableObject {
    @Published var statusMessage: String = "Waiting for mesh data..."
    @Published var triangleCount: Int = 0
    @Published var vertexCount: Int = 0
    
    let scene = SCNScene()
    var sceneView: SCNView?
    private var meshNode: SCNNode?
    private var pollingTimer: Timer?
    private var lastMeshETag: String?
    private var isLoading = false
    
    init() {
        setupScene()
    }
    
    private func setupScene() {
        // Add ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = UIColor.white.withAlphaComponent(0.5)
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)
        
        // Add directional lights
        let light1 = SCNLight()
        light1.type = .directional
        light1.color = UIColor.white
        light1.intensity = 800
        let lightNode1 = SCNNode()
        lightNode1.light = light1
        lightNode1.position = SCNVector3(5, 10, 5)
        scene.rootNode.addChildNode(lightNode1)
        
        let light2 = SCNLight()
        light2.type = .directional
        light2.color = UIColor.white
        light2.intensity = 400
        let lightNode2 = SCNNode()
        lightNode2.light = light2
        lightNode2.position = SCNVector3(-5, 5, -5)
        scene.rootNode.addChildNode(lightNode2)
        
        // Add hemisphere light
        let hemisphereLight = SCNLight()
        hemisphereLight.type = .ambient
        hemisphereLight.color = UIColor.white
        hemisphereLight.intensity = 300
        let hemisphereNode = SCNNode()
        hemisphereNode.light = hemisphereLight
        scene.rootNode.addChildNode(hemisphereNode)
        
        // Add grid helper
        let grid = SCNFloor()
        grid.reflectionFalloffEnd = 0
        let gridMaterial = SCNMaterial()
        gridMaterial.diffuse.contents = UIColor(white: 0.5, alpha: 0.3)
        grid.materials = [gridMaterial]
        let gridNode = SCNNode(geometry: grid)
        gridNode.position = SCNVector3(0, -0.01, 0)
        scene.rootNode.addChildNode(gridNode)
        
        // Add axes helper
        let axes = SCNNode()
        // X axis (red)
        let xAxis = SCNBox(width: 2, height: 0.02, length: 0.02, chamferRadius: 0)
        xAxis.firstMaterial?.diffuse.contents = UIColor.red
        axes.addChildNode(SCNNode(geometry: xAxis))
        // Y axis (green)
        let yAxis = SCNBox(width: 0.02, height: 2, length: 0.02, chamferRadius: 0)
        yAxis.firstMaterial?.diffuse.contents = UIColor.green
        axes.addChildNode(SCNNode(geometry: yAxis))
        // Z axis (blue)
        let zAxis = SCNBox(width: 0.02, height: 0.02, length: 2, chamferRadius: 0)
        zAxis.firstMaterial?.diffuse.contents = UIColor.blue
        axes.addChildNode(SCNNode(geometry: zAxis))
        scene.rootNode.addChildNode(axes)
    }
    
    func startPolling(laptopIP: String, token: String) {
        stopPolling()
        
        // Load immediately
        loadMesh(laptopIP: laptopIP, token: token)
        
        // Poll every 300ms for real-time updates
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.loadMesh(laptopIP: laptopIP, token: token)
        }
    }
    
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    private func loadMesh(laptopIP: String, token: String) {
        guard !isLoading else { return }
        
        let meshURL = URL(string: "http://\(laptopIP):8080/mesh?token=\(token)")!
        
        // Check if mesh exists and has changed
        var request = URLRequest(url: meshURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.isLoading = false
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                return
            }
            
            if httpResponse.statusCode == 404 {
                DispatchQueue.main.async {
                    self.statusMessage = "Waiting for mesh data... Scan in progress"
                    self.isLoading = false
                }
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.statusMessage = "Error: HTTP \(httpResponse.statusCode)"
                    self.isLoading = false
                }
                return
            }
            
            // Check if mesh has changed
            let etag = httpResponse.value(forHTTPHeaderField: "ETag")
            if etag == self.lastMeshETag && self.meshNode != nil {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                return
            }
            
            self.lastMeshETag = etag
            self.isLoading = true
            
            DispatchQueue.main.async {
                self.statusMessage = "Loading mesh..."
            }
            
            // Load the mesh file
            let loadRequest = URLRequest(url: meshURL.appendingQueryItem(name: "t", value: "\(Date().timeIntervalSince1970)"))
            let loadTask = URLSession.shared.dataTask(with: loadRequest) { [weak self] data, response, error in
                guard let self = self else { return }
                
                defer {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                }
                
                if let error = error {
                    DispatchQueue.main.async {
                        self.statusMessage = "Error loading mesh: \(error.localizedDescription)"
                    }
                    return
                }
                
                guard let data = data else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Error: No mesh data"
                    }
                    return
                }
                
                // Load PLY file using Model I/O
                self.loadPLYData(data)
            }
            
            loadTask.resume()
        }
        
        task.resume()
    }
    
    private func loadPLYData(_ data: Data) {
        // Create temporary file for Model I/O
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("mesh_\(UUID().uuidString).ply")
        
        do {
            try data.write(to: tempURL)
            
            // Load using Model I/O
            let asset = MDLAsset(url: tempURL)
            
            guard let object = asset.object(at: 0) as? MDLMesh else {
                DispatchQueue.main.async {
                    self.statusMessage = "Error: Invalid mesh format"
                }
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            
            // Convert to SceneKit geometry
            let sceneKitGeometry = SCNGeometry(mdlMesh: object)
            
            // Create material
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: 0.42, green: 0.61, blue: 0.82, alpha: 1.0)
            material.metalness.contents = 0.1
            material.roughness.contents = 0.7
            material.lightingModel = .physicallyBased
            
            sceneKitGeometry.materials = [material]
            
            // Get statistics
            let vertexCount = object.vertexCount
            let triangleCount = object.faceCount
            
            // Remove old mesh
            if let oldNode = self.meshNode {
                oldNode.removeFromParentNode()
            }
            
            // Create new mesh node
            let meshNode = SCNNode(geometry: sceneKitGeometry)
            
            // Center and scale mesh
            let boundingBox = meshNode.boundingBox
            let center = SCNVector3(
                (boundingBox.min.x + boundingBox.max.x) / 2,
                (boundingBox.min.y + boundingBox.max.y) / 2,
                (boundingBox.min.z + boundingBox.max.z) / 2
            )
            meshNode.position = SCNVector3(-center.x, -center.y, -center.z)
            
            // Scale to fit
            let size = SCNVector3(
                boundingBox.max.x - boundingBox.min.x,
                boundingBox.max.y - boundingBox.min.y,
                boundingBox.max.z - boundingBox.min.z
            )
            let maxDim = max(size.x, size.y, size.z)
            if maxDim > 0 {
                let scale: Float = 3.0 / maxDim
                meshNode.scale = SCNVector3(scale, scale, scale)
            }
            
            self.meshNode = meshNode
            self.scene.rootNode.addChildNode(meshNode)
            
            DispatchQueue.main.async {
                self.vertexCount = Int(vertexCount)
                self.triangleCount = Int(triangleCount)
                self.statusMessage = "Mesh loaded: \(triangleCount.formatted()) triangles, \(vertexCount.formatted()) vertices"
            }
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)
            
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Error: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
    
    func resetCamera() {
        guard let sceneView = sceneView else { return }
        
        // Reset camera to default position
        let cameraNode = sceneView.pointOfView ?? SCNNode()
        cameraNode.position = SCNVector3(5, 5, 5)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        sceneView.pointOfView = cameraNode
    }
}

// MARK: - URL Extension

extension URL {
    func appendingQueryItem(name: String, value: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: name, value: value))
        components?.queryItems = queryItems
        return components?.url ?? self
    }
}
