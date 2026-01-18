import React, { useEffect, useRef, useState, useCallback } from 'react';
import * as THREE from 'three';
import { PLYLoader } from 'three/examples/jsm/loaders/PLYLoader.js';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import './MeshViewer.css';

function MeshViewer({ token, serverUrl, ws }) {
  const mountRef = useRef(null);
  const sceneRef = useRef(null);
  const rendererRef = useRef(null);
  const controlsRef = useRef(null);
  const cameraRef = useRef(null);
  const meshRef = useRef(null);
  const [meshStatus, setMeshStatus] = useState('Waiting for mesh data...');
  const [meshStats, setMeshStats] = useState({ vertices: 0, triangles: 0 });
  const [isLoading, setIsLoading] = useState(false);
  const lastMeshHashRef = useRef(null);
  const animationFrameRef = useRef(null);

  useEffect(() => {
    if (!mountRef.current || !token) return;

    // Initialize Three.js scene
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x222222);
    sceneRef.current = scene;

    const camera = new THREE.PerspectiveCamera(
      75,
      mountRef.current.clientWidth / mountRef.current.clientHeight,
      0.1,
      1000
    );
    camera.position.set(5, 5, 5);
    camera.lookAt(0, 0, 0);
    cameraRef.current = camera;

    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(mountRef.current.clientWidth, mountRef.current.clientHeight);
    renderer.setPixelRatio(window.devicePixelRatio);
    mountRef.current.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    // Add orbit controls with enhanced settings
    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.1;
    controls.enablePan = true;
    controls.enableZoom = true;
    controls.enableRotate = true;
    controls.minDistance = 0.5;
    controls.maxDistance = 50;
    controls.screenSpacePanning = false;
    controls.target.set(0, 0, 0);
    controlsRef.current = controls;

    // Add enhanced lighting
    const ambientLight = new THREE.AmbientLight(0xffffff, 0.5);
    scene.add(ambientLight);
    
    const directionalLight1 = new THREE.DirectionalLight(0xffffff, 0.8);
    directionalLight1.position.set(5, 10, 5);
    scene.add(directionalLight1);
    
    const directionalLight2 = new THREE.DirectionalLight(0xffffff, 0.4);
    directionalLight2.position.set(-5, 5, -5);
    scene.add(directionalLight2);
    
    // Add hemisphere light for better overall illumination
    const hemisphereLight = new THREE.HemisphereLight(0xffffff, 0x444444, 0.3);
    scene.add(hemisphereLight);
    
    // Add grid helper for reference
    const gridHelper = new THREE.GridHelper(10, 10, 0x888888, 0x444444);
    scene.add(gridHelper);
    
    // Add axes helper
    const axesHelper = new THREE.AxesHelper(2);
    scene.add(axesHelper);

    // Animation loop
    const animate = () => {
      animationFrameRef.current = requestAnimationFrame(animate);
      if (controlsRef.current) {
        controlsRef.current.update();
      }
      if (rendererRef.current && sceneRef.current && cameraRef.current) {
        rendererRef.current.render(sceneRef.current, cameraRef.current);
      }
    };
    animate();

    // Handle resize
    const handleResize = () => {
      if (!mountRef.current) return;
      camera.aspect = mountRef.current.clientWidth / mountRef.current.clientHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(mountRef.current.clientWidth, mountRef.current.clientHeight);
    };
    window.addEventListener('resize', handleResize);

    // Cleanup
    return () => {
      window.removeEventListener('resize', handleResize);
      if (animationFrameRef.current) {
        cancelAnimationFrame(animationFrameRef.current);
      }
      if (mountRef.current && renderer.domElement && mountRef.current.contains(renderer.domElement)) {
        mountRef.current.removeChild(renderer.domElement);
      }
      renderer.dispose();
      if (meshRef.current) {
        meshRef.current.geometry?.dispose();
        meshRef.current.material?.dispose();
      }
    };
  }, [token]);

  // Load mesh function
  const loadMesh = useCallback(async () => {
    if (!token || isLoading) return;

    try {
      setIsLoading(true);
      
      // Check if mesh exists using HEAD request
      const checkResponse = await fetch(`${serverUrl}/mesh?token=${token}`, {
        method: 'HEAD',
        cache: 'no-cache'
      });

      if (!checkResponse.ok) {
        if (checkResponse.status === 404) {
          setMeshStatus('Waiting for mesh data... Scan in progress');
          setIsLoading(false);
        } else {
          setMeshStatus('Error checking mesh');
          setIsLoading(false);
        }
        return;
      }

      // Check if mesh has changed
      const etag = checkResponse.headers.get('etag');
      const lastModified = checkResponse.headers.get('last-modified');
      
      if (etag === lastMeshHashRef.current && meshRef.current) {
        // Mesh hasn't changed, skip reload
        setIsLoading(false);
        return;
      }
      
      // Mesh has changed or is new
      lastMeshHashRef.current = etag;

      setMeshStatus('Loading mesh...');

      // Load mesh with cache busting
      const loader = new PLYLoader();
      const meshUrl = `${serverUrl}/mesh?token=${token}&t=${Date.now()}`;

      loader.load(
        meshUrl,
        (geometry) => {
          const vertexCount = geometry.attributes.position?.count || 0;
          const triangleCount = geometry.index 
            ? geometry.index.count / 3 
            : (geometry.attributes.position ? Math.floor(geometry.attributes.position.count / 3) : 0);
          
          setMeshStats({
            vertices: vertexCount,
            triangles: triangleCount
          });
          
          setMeshStatus(`Mesh loaded: ${triangleCount.toLocaleString()} triangles, ${vertexCount.toLocaleString()} vertices`);
          setIsLoading(false);

          // Remove old mesh if exists
          if (meshRef.current && sceneRef.current) {
            sceneRef.current.remove(meshRef.current);
            if (meshRef.current.geometry) {
              meshRef.current.geometry.dispose();
            }
            if (meshRef.current.material) {
              if (Array.isArray(meshRef.current.material)) {
                meshRef.current.material.forEach(mat => mat.dispose());
              } else {
                meshRef.current.material.dispose();
              }
            }
          }

          // Compute normals if not present
          if (!geometry.attributes.normal) {
            geometry.computeVertexNormals();
          }

          // Create material with better appearance
          const material = new THREE.MeshStandardMaterial({
            color: 0x6b9bd1,
            metalness: 0.1,
            roughness: 0.7,
            flatShading: false,
            vertexColors: geometry.hasAttribute('color')
          });

          // Create mesh
          const mesh = new THREE.Mesh(geometry, material);
          meshRef.current = mesh;
          
          if (sceneRef.current) {
            sceneRef.current.add(mesh);

            // Center and scale mesh
            geometry.computeBoundingBox();
            const box = geometry.boundingBox;
            const center = new THREE.Vector3();
            box.getCenter(center);
            geometry.translate(-center.x, -center.y, -center.z);

            // Scale to fit view
            const size = new THREE.Vector3();
            box.getSize(size);
            const maxDim = Math.max(size.x, size.y, size.z);
            if (maxDim > 0) {
              const scale = 3 / maxDim;
              mesh.scale.multiplyScalar(scale);
            }

            // Update camera and controls to view mesh
            if (controlsRef.current && cameraRef.current) {
              controlsRef.current.target.set(0, 0, 0);
              
              // Set camera to nice viewing angle
              const distance = maxDim * 1.5;
              cameraRef.current.position.set(distance, distance * 0.7, distance);
              cameraRef.current.lookAt(0, 0, 0);
              controlsRef.current.update();
            }
          }
        },
        (progress) => {
          if (progress.total > 0) {
            const percent = (progress.loaded / progress.total) * 100;
            setMeshStatus(`Loading mesh: ${percent.toFixed(0)}%`);
          }
        },
        (error) => {
          console.error('Error loading mesh:', error);
          setMeshStatus('Error loading mesh');
          setIsLoading(false);
        }
      );
    } catch (error) {
      console.error('Error checking mesh:', error);
      setMeshStatus('Error checking mesh');
      setIsLoading(false);
    }
  }, [token, serverUrl, isLoading]);

  // Poll for mesh updates (faster polling for real-time feel)
  useEffect(() => {
    if (!token) return;

    // Load immediately
    loadMesh();

    // Poll every 300ms for smooth real-time mesh updates
    const interval = setInterval(loadMesh, 300);

    return () => {
      clearInterval(interval);
    };
  }, [token, loadMesh]);

  if (!token) {
    return (
      <div className="mesh-viewer">
        <h2>Mesh Viewer</h2>
        <div className="mesh-placeholder">
          <p>Enter a token to view mesh</p>
        </div>
      </div>
    );
  }

  const handleResetView = () => {
    if (controlsRef.current && cameraRef.current && meshRef.current) {
      controlsRef.current.target.set(0, 0, 0);
      cameraRef.current.position.set(5, 5, 5);
      cameraRef.current.lookAt(0, 0, 0);
      controlsRef.current.update();
    }
  };

  return (
    <div className="mesh-viewer">
      <div className="mesh-header">
        <h2>Live 3D Mesh</h2>
        <button 
          onClick={handleResetView}
          className="reset-view-btn"
          title="Reset camera view"
        >
          ↻ Reset View
        </button>
      </div>
      <div className="mesh-status-bar">
        <div className="mesh-status">{meshStatus}</div>
        {meshStats.triangles > 0 && (
          <div className="mesh-stats">
            <span className="stat-item">Triangles: {meshStats.triangles.toLocaleString()}</span>
            <span className="stat-item">Vertices: {meshStats.vertices.toLocaleString()}</span>
          </div>
        )}
      </div>
      <div ref={mountRef} className="mesh-container" />
      <div className="mesh-controls-hint">
        <div className="control-hint">
          <strong>Controls:</strong>
          <span>🖱️ Left Click + Drag: Rotate</span>
          <span>🖱️ Right Click + Drag: Pan</span>
          <span>🖱️ Scroll: Zoom</span>
          <span>📱 Touch: Pinch to zoom, drag to rotate</span>
        </div>
      </div>
    </div>
  );
}

export default MeshViewer;
