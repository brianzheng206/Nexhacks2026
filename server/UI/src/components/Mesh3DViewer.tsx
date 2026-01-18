import { useEffect, useRef } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

interface MeshData {
  vertices: number[][];
  faces: number[][];
  colors: number[][];
  transform?: number[];
}

interface Mesh3DViewerProps {
  meshData: Map<string, MeshData>;
  className?: string;
}

export default function Mesh3DViewer({ meshData, className = '' }: Mesh3DViewerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const sceneRef = useRef<THREE.Scene | null>(null);
  const rendererRef = useRef<THREE.WebGLRenderer | null>(null);
  const cameraRef = useRef<THREE.PerspectiveCamera | null>(null);
  const controlsRef = useRef<OrbitControls | null>(null);
  const meshesRef = useRef<Map<string, THREE.Mesh>>(new Map());
  const animationFrameRef = useRef<number | null>(null);

  useEffect(() => {
    if (!containerRef.current) return;

    const container = containerRef.current;
    const width = container.clientWidth || 800;
    const height = container.clientHeight || 600;

    // Initialize Three.js scene
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x1a1a1a);
    sceneRef.current = scene;

    // Camera
    const camera = new THREE.PerspectiveCamera(75, width / height, 0.1, 1000);
    camera.position.set(0, 2, 5);
    camera.lookAt(0, 0, 0);
    cameraRef.current = camera;

    // Renderer
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(width, height);
    renderer.setPixelRatio(window.devicePixelRatio);
    container.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    // OrbitControls for camera interaction
    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.05;
    controls.enableZoom = true;
    controls.enablePan = true;
    controlsRef.current = controls;

    // Lights
    scene.add(new THREE.AmbientLight(0xffffff, 0.6));
    const directionalLight = new THREE.DirectionalLight(0xffffff, 0.8);
    directionalLight.position.set(5, 10, 5);
    scene.add(directionalLight);
    scene.add(new THREE.HemisphereLight(0xffffbb, 0x080820, 0.5));

    // Grid helper
    const gridHelper = new THREE.GridHelper(10, 10, 0x444444, 0x444444);
    scene.add(gridHelper);

    // Animation loop
    function animate() {
      animationFrameRef.current = requestAnimationFrame(animate);
      controls.update(); // Update controls for damping
      renderer.render(scene, camera);
    }
    animate();

    // Handle resize
    const handleResize = () => {
      if (!containerRef.current || !camera || !renderer) return;
      const newWidth = container.clientWidth || 800;
      const newHeight = container.clientHeight || 600;
      camera.aspect = newWidth / newHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(newWidth, newHeight);
    };
    window.addEventListener('resize', handleResize);

    // Cleanup
    return () => {
      window.removeEventListener('resize', handleResize);
      if (animationFrameRef.current !== null) {
        cancelAnimationFrame(animationFrameRef.current);
      }
      controls.dispose();
      if (container && renderer.domElement && container.contains(renderer.domElement)) {
        container.removeChild(renderer.domElement);
      }
      renderer.dispose();
    };
  }, []);

  // Update meshes when meshData changes
  useEffect(() => {
    if (!sceneRef.current) return;

    const scene = sceneRef.current;
    const meshes = meshesRef.current;

    // Remove old meshes that are no longer in meshData
    meshes.forEach((mesh, anchorId) => {
      if (!meshData.has(anchorId)) {
        scene.remove(mesh);
        mesh.geometry.dispose();
        if (mesh.material instanceof THREE.Material) {
          mesh.material.dispose();
        }
        meshes.delete(anchorId);
      }
    });

    // Add/update meshes
    meshData.forEach((data, anchorId) => {
      if (!data.vertices || !data.faces || !data.colors) {
        console.warn('[Mesh3DViewer] Missing mesh data for anchor:', anchorId);
        return;
      }

      try {
        // Create geometry
        const geometry = new THREE.BufferGeometry();

        // Flatten vertices array
        const positions: number[] = [];
        data.vertices.forEach(v => {
          if (Array.isArray(v) && v.length >= 3) {
            positions.push(v[0], v[1], v[2]);
          }
        });

        // Flatten colors array
        const colors: number[] = [];
        data.colors.forEach(c => {
          if (Array.isArray(c) && c.length >= 3) {
            colors.push(c[0], c[1], c[2]);
          }
        });

        // Flatten faces (indices)
        const indices: number[] = [];
        data.faces.forEach(f => {
          if (Array.isArray(f) && f.length >= 3) {
            indices.push(f[0], f[1], f[2]);
          }
        });

        if (positions.length === 0 || indices.length === 0) {
          console.warn('[Mesh3DViewer] Empty mesh data for anchor:', anchorId);
          return;
        }

        geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
        if (colors.length === positions.length) {
          geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
        }
        geometry.setIndex(indices);
        geometry.computeVertexNormals();

        // Create material with vertex colors
        const material = new THREE.MeshStandardMaterial({
          vertexColors: colors.length === positions.length,
          flatShading: false,
          metalness: 0.1,
          roughness: 0.7
        });

        // Create mesh
        const mesh = new THREE.Mesh(geometry, material);
        
        // Apply transform if provided (column-major matrix from ARKit)
        if (data.transform && data.transform.length === 16) {
          const m = data.transform;
          mesh.matrix.set(
            m[0], m[4], m[8], m[12],   // Column 0 -> Row 0
            m[1], m[5], m[9], m[13],   // Column 1 -> Row 1
            m[2], m[6], m[10], m[14],  // Column 2 -> Row 2
            m[3], m[7], m[11], m[15]   // Column 3 -> Row 3
          );
          mesh.matrixAutoUpdate = false;
        }

        // Remove old mesh if exists
        if (meshes.has(anchorId)) {
          const oldMesh = meshes.get(anchorId)!;
          scene.remove(oldMesh);
          oldMesh.geometry.dispose();
          if (oldMesh.material instanceof THREE.Material) {
            oldMesh.material.dispose();
          }
        }

        // Add new mesh
        scene.add(mesh);
        meshes.set(anchorId, mesh);
      } catch (error) {
        console.error('[Mesh3DViewer] Error processing mesh:', error, anchorId);
      }
    });

    // Center and scale all meshes (only once per mesh, don't modify positions repeatedly)
    if (meshes.size > 0) {
      const box = new THREE.Box3();
      let hasUncentered = false;
      meshes.forEach(mesh => {
        box.expandByObject(mesh);
        if (!mesh.userData.centered) {
          hasUncentered = true;
        }
      });

      if (hasUncentered) {
        const center = box.getCenter(new THREE.Vector3());
        const size = box.getSize(new THREE.Vector3());
        const maxDim = Math.max(size.x, size.y, size.z);

        if (maxDim > 0.1) { // Only if mesh has reasonable size
          meshes.forEach(mesh => {
            if (!mesh.userData.centered) {
              // Get current world position
              const worldPos = new THREE.Vector3();
              mesh.getWorldPosition(worldPos);
              // Translate to center
              mesh.position.sub(center);
              mesh.userData.centered = true;
            }
          });

          // Reset camera position if needed
          if (cameraRef.current && controlsRef.current) {
            cameraRef.current.position.set(0, 2, 5);
            cameraRef.current.lookAt(0, 0, 0);
            controlsRef.current.target.set(0, 0, 0);
            controlsRef.current.update();
          }
        }
      }
    }
  }, [meshData]);

  return (
    <div 
      ref={containerRef} 
      className={className}
      style={{ width: '100%', height: '100%', minHeight: '400px' }}
    />
  );
}
