import React, { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';
import { PLYLoader } from 'three/examples/jsm/loaders/PLYLoader.js';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import './MeshViewer.css';

function MeshViewer({ token, serverUrl }) {
  const mountRef = useRef(null);
  const sceneRef = useRef(null);
  const rendererRef = useRef(null);
  const controlsRef = useRef(null);
  const meshRef = useRef(null);
  const [meshStatus, setMeshStatus] = useState('No mesh available');

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
    camera.position.set(0, 0, 5);

    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(mountRef.current.clientWidth, mountRef.current.clientHeight);
    renderer.setPixelRatio(window.devicePixelRatio);
    mountRef.current.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    // Add orbit controls
    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.05;
    controlsRef.current = controls;

    // Add lights
    const ambientLight = new THREE.AmbientLight(0xffffff, 0.6);
    scene.add(ambientLight);
    const directionalLight = new THREE.DirectionalLight(0xffffff, 0.8);
    directionalLight.position.set(5, 5, 5);
    scene.add(directionalLight);

    // Animation loop
    const animate = () => {
      requestAnimationFrame(animate);
      controls.update();
      renderer.render(scene, camera);
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
      if (mountRef.current && renderer.domElement) {
        mountRef.current.removeChild(renderer.domElement);
      }
      renderer.dispose();
    };
  }, [token]);

  // Poll for mesh every 2 seconds
  useEffect(() => {
    if (!token) return;

    let lastMeshHash = null;
    let isLoading = false;
    let lastModified = null;

    const loadMesh = async () => {
      if (isLoading) return; // Prevent concurrent loads

      try {
        // Check if mesh exists using HEAD request
        const checkResponse = await fetch(`${serverUrl}/mesh?token=${token}`, {
          method: 'HEAD'
        });

        if (!checkResponse.ok) {
          if (checkResponse.status === 404) {
            setMeshStatus('Waiting for chunks... Mesh will appear as chunks are processed');
          } else {
            setMeshStatus('Error checking mesh');
          }
          return;
        }

        // Check if mesh has changed (using ETag or Last-Modified if available)
        const etag = checkResponse.headers.get('etag');
        const lastModifiedHeader = checkResponse.headers.get('last-modified');
        
        // Check if mesh has changed
        if (etag === lastMeshHash && meshRef.current && lastModified === lastModifiedHeader) {
          // Mesh hasn't changed, skip reload
          return;
        }
        
        // Mesh has changed or is new
        lastMeshHash = etag;
        lastModified = lastModifiedHeader;

        isLoading = true;
        setMeshStatus('Loading mesh...');

        // Mesh exists, load it
        const loader = new PLYLoader();
        // Add cache busting to force reload when file changes
        const meshUrl = `${serverUrl}/mesh?token=${token}&t=${Date.now()}`;

        loader.load(
          meshUrl,
          (geometry) => {
            const vertexCount = geometry.attributes.position?.count || 0;
            const triangleCount = geometry.index ? geometry.index.count / 3 : (geometry.attributes.position ? geometry.attributes.position.count / 3 : 0);
            setMeshStatus(`Building mesh... ${Math.floor(triangleCount).toLocaleString()} triangles, ${vertexCount.toLocaleString()} vertices`);
            isLoading = false;

            // Remove old mesh if exists
            if (meshRef.current && sceneRef.current) {
              sceneRef.current.remove(meshRef.current);
              meshRef.current.geometry.dispose();
              if (meshRef.current.material) {
                meshRef.current.material.dispose();
              }
            }

            // Compute normals if not present
            if (!geometry.attributes.normal) {
              geometry.computeVertexNormals();
            }

            // Create material
            const material = new THREE.MeshStandardMaterial({
              color: 0x888888,
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

              // Scale to fit
              const size = new THREE.Vector3();
              box.getSize(size);
              const maxDim = Math.max(size.x, size.y, size.z);
              if (maxDim > 0) {
                const scale = 2 / maxDim;
                mesh.scale.multiplyScalar(scale);
              }

              // Update camera to view mesh
              if (controlsRef.current) {
                controlsRef.current.target.set(0, 0, 0);
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
            isLoading = false;
          }
        );
      } catch (error) {
        console.error('Error checking mesh:', error);
        setMeshStatus('Error checking mesh');
        isLoading = false;
      }
    };

    // Load immediately
    loadMesh();

    // Poll every 500ms for smooth real-time mesh updates
    const interval = setInterval(loadMesh, 500);

    return () => {
      clearInterval(interval);
      isLoading = false;
    };
  }, [token, serverUrl]);

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

  return (
    <div className="mesh-viewer">
      <h2>Live 3D Mesh Generation</h2>
      <div className="mesh-status">{meshStatus}</div>
      <div ref={mountRef} className="mesh-container" style={{width: '100%', height: '500px', border: '1px solid #ccc', borderRadius: '8px'}} />
      <div style={{marginTop: '10px', fontSize: '0.9em', color: '#666', padding: '0 1rem'}}>
        Mesh updates automatically as chunks are processed. Rotate with mouse/touch.
      </div>
    </div>
  );
}

export default MeshViewer;
