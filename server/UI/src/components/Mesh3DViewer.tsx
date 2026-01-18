import { useEffect, useRef } from 'react';
import * as THREE from 'three';

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
  const controlsRef = useRef<any>(null);
  const meshesRef = useRef<Map<string, THREE.Mesh>>(new Map());

  useEffect(() => {
    if (!containerRef.current) return;

    // Initialize Three.js scene
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x1a1a1a);
    sceneRef.current = scene;

    // Camera
    const camera = new THREE.PerspectiveCamera(
      75,
      containerRef.current.clientWidth / containerRef.current.clientHeight,
      0.1,
      1000
    );
    camera.position.set(0, 2, 5);
    camera.lookAt(0, 0, 0);
    cameraRef.current = camera;

    // Renderer
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(containerRef.current.clientWidth, containerRef.current.clientHeight);
    renderer.setPixelRatio(window.devicePixelRatio);
    containerRef.current.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    // Lights
    scene.add(new THREE.AmbientLight(0xffffff, 0.6));
    scene.add(new THREE.DirectionalLight(0xffffff, 0.8));
    scene.add(new THREE.HemisphereLight(0xffffbb, 0x080820, 0.5));

    // Grid helper
    const gridHelper = new THREE.GridHelper(10, 10, 0x444444, 0x444444);
    scene.add(gridHelper);

    // OrbitControls (we'll add this via CDN or import)
    // For now, we'll implement basic mouse controls manually

    // Animation loop
    let animationId: number;
    function animate() {
      animationId = requestAnimationFrame(animate);
      renderer.render(scene, camera);
    }
    animate();

    // Handle resize
    const handleResize = () => {
      if (!containerRef.current || !camera || !renderer) return;
      camera.aspect = containerRef.current.clientWidth / containerRef.current.clientHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(containerRef.current.clientWidth, containerRef.current.clientHeight);
    };
    window.addEventListener('resize', handleResize);

    // Cleanup
    return () => {
      window.removeEventListener('resize', handleResize);
      cancelAnimationFrame(animationId);
      if (containerRef.current && renderer.domElement) {
        containerRef.current.removeChild(renderer.domElement);
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
      if (!data.vertices || !data.faces || !data.colors) return;

      // Create geometry
      const geometry = new THREE.BufferGeometry();

      // Flatten vertices array
      const positions: number[] = [];
      data.vertices.forEach(v => {
        positions.push(v[0], v[1], v[2]);
      });

      // Flatten colors array
      const colors: number[] = [];
      data.colors.forEach(c => {
        colors.push(c[0], c[1], c[2]);
      });

      // Flatten faces (indices)
      const indices: number[] = [];
      data.faces.forEach(f => {
        indices.push(f[0], f[1], f[2]);
      });

      geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
      geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
      geometry.setIndex(indices);
      geometry.computeVertexNormals();

      // Create material with vertex colors
      const material = new THREE.MeshStandardMaterial({
        vertexColors: true,
        flatShading: false,
        metalness: 0.1,
        roughness: 0.7
      });

      // Apply transform if provided
      const mesh = new THREE.Mesh(geometry, material);
      if (data.transform && data.transform.length === 16) {
        const m = data.transform;
        mesh.matrix.set(
          m[0], m[1], m[2], m[3],
          m[4], m[5], m[6], m[7],
          m[8], m[9], m[10], m[11],
          m[12], m[13], m[14], m[15]
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
    });

    // Center and scale all meshes
    if (meshes.size > 0) {
      const box = new THREE.Box3();
      meshes.forEach(mesh => box.expandByObject(mesh));
      const center = box.getCenter(new THREE.Vector3());
      const size = box.getSize(new THREE.Vector3());
      const maxDim = Math.max(size.x, size.y, size.z);

      if (maxDim > 0 && cameraRef.current) {
        const scale = 3 / maxDim;
        meshes.forEach(mesh => {
          mesh.position.sub(center);
          mesh.scale.multiplyScalar(scale);
        });
        cameraRef.current.position.set(0, 2, 5);
        cameraRef.current.lookAt(0, 0, 0);
      }
    }
  }, [meshData]);

  return <div ref={containerRef} className={className} />;
}
