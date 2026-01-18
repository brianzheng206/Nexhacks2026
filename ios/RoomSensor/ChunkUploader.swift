//
//  ChunkUploader.swift
//  RoomSensor
//
//  Created on 2024
//

import Foundation

struct KeyframeInfo {
    let frameId: String
    let rgbPath: URL
    let depthPath: URL
    let metaPath: URL
    var isUploaded: Bool = false
}

class ChunkUploader {
    private let laptopIP: String
    private let token: String
    private let fileManager = FileManager.default
    private var uploadQueue: [URL] = []
    private var isUploading = false
    private let maxRetries = 3
    private let baseRetryDelay: TimeInterval = 1.0
    
    init(laptopIP: String, token: String) {
        self.laptopIP = laptopIP
        self.token = token
    }
    
    func uploadChunk(chunkZipURL: URL, chunkId: String, frameCount: Int, completion: @escaping (Bool, Error?) -> Void) {
        uploadWithRetry(chunkZipURL: chunkZipURL, chunkId: chunkId, frameCount: frameCount, attempt: 0, completion: completion)
    }
    
    private func uploadWithRetry(chunkZipURL: URL, chunkId: String, frameCount: Int, attempt: Int, completion: @escaping (Bool, Error?) -> Void) {
        guard attempt < maxRetries else {
            completion(false, NSError(domain: "ChunkUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Max retries exceeded"]))
            return
        }
        
        let urlString = "http://\(laptopIP):8080/upload/chunk?token=\(token)&chunkId=\(chunkId)"
        guard let url = URL(string: urlString) else {
            completion(false, NSError(domain: "ChunkUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(chunkId).zip\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/zip\r\n\r\n".data(using: .utf8)!)
        
        guard let fileData = try? Data(contentsOf: chunkZipURL) else {
            completion(false, NSError(domain: "ChunkUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read zip file"]))
            return
        }
        
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("Upload error (attempt \(attempt + 1)): \(error)")
                let delay = self?.baseRetryDelay * pow(2.0, Double(attempt))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay!) {
                    self?.uploadWithRetry(chunkZipURL: chunkZipURL, chunkId: chunkId, frameCount: frameCount, attempt: attempt + 1, completion: completion)
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(false, NSError(domain: "ChunkUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
                return
            }
            
            if httpResponse.statusCode == 200 {
                print("Chunk \(chunkId) uploaded successfully")
                completion(true, nil)
            } else {
                let errorMsg = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown error"
                print("Upload failed with status \(httpResponse.statusCode): \(errorMsg)")
                
                if attempt < self?.maxRetries ?? 3 - 1 {
                    let delay = self?.baseRetryDelay * pow(2.0, Double(attempt))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay!) {
                        self?.uploadWithRetry(chunkZipURL: chunkZipURL, chunkId: chunkId, frameCount: frameCount, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(false, NSError(domain: "ChunkUploader", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg]))
                }
            }
        }
        
        task.resume()
    }
}
