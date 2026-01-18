import { useEffect, useRef } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

interface WallDimensions {
  width?: number;
  height?: number;
  length?: number;
}

interface WallData {
  identifier?: string;
  transform?: number[];
  dimensions?: WallDimensions;
}

interface RoomPlanViewerProps {
  walls: WallData[];
  className?: string;
}

export default function RoomPlanViewer({ walls, className = '' }: RoomPlanViewerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const sceneRef = useRef<THREE.Scene | null>(null);
  const rendererRef = useRef<THREE.WebGLRenderer | null>(null);
  const cameraRef = useRef<THREE.PerspectiveCamera | null>(null);
  const controlsRef = useRef<OrbitControls | null>(null);
  const meshesRef = useRef<Map<string, THREE.Mesh>>(new Map());
  const animationFrameRef = useRef<number | null>(null);
  const hasFitRef = useRef(false);
  const materialRef = useRef<THREE.MeshStandardMaterial | null>(null);

  useEffect(() => {
    if (!containerRef.current) return;

    const container = containerRef.current;
    const width = container.clientWidth || 800;
    const height = container.clientHeight || 600;

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0f1115);
    sceneRef.current = scene;

    const camera = new THREE.PerspectiveCamera(65, width / height, 0.1, 1000);
    camera.position.set(2.5, 2.5, 4.5);
    camera.lookAt(0, 0, 0);
    cameraRef.current = camera;

    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(width, height);
    renderer.setPixelRatio(window.devicePixelRatio);
    container.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.enableZoom = true;
    controls.enablePan = true;
    controlsRef.current = controls;

    scene.add(new THREE.AmbientLight(0xffffff, 0.5));
    const directionalLight = new THREE.DirectionalLight(0xffffff, 0.8);
    directionalLight.position.set(5, 10, 5);
    scene.add(directionalLight);
    scene.add(new THREE.HemisphereLight(0x9db4ff, 0x0a0a12, 0.4));

    const gridHelper = new THREE.GridHelper(10, 10, 0x2c2c2c, 0x2c2c2c);
    scene.add(gridHelper);

    materialRef.current = new THREE.MeshStandardMaterial({
      color: 0x9fb8ff,
      metalness: 0.05,
      roughness: 0.6,
      opacity: 0.9,
      transparent: true,
    });

    function animate() {
      animationFrameRef.current = requestAnimationFrame(animate);
      controls.update();
      renderer.render(scene, camera);
    }
    animate();

    const handleResize = () => {
      if (!containerRef.current || !camera || !renderer) return;
      const newWidth = container.clientWidth || 800;
      const newHeight = container.clientHeight || 600;
      camera.aspect = newWidth / newHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(newWidth, newHeight);
    };
    window.addEventListener('resize', handleResize);

    return () => {
      window.removeEventListener('resize', handleResize);
      if (animationFrameRef.current !== null) {
        cancelAnimationFrame(animationFrameRef.current);
      }
      controls.dispose();
      materialRef.current?.dispose();
      meshesRef.current.forEach(mesh => {
        mesh.geometry.dispose();
      });
      meshesRef.current.clear();
      if (container && renderer.domElement && container.contains(renderer.domElement)) {
        container.removeChild(renderer.domElement);
      }
      renderer.dispose();
    };
  }, []);

  useEffect(() => {
    if (!sceneRef.current) return;

    const scene = sceneRef.current;
    const meshes = meshesRef.current;
    const activeIds = new Set<string>();

    if (!walls.length) {
      hasFitRef.current = false;
    }

    walls.forEach((wall, index) => {
      const wallId = wall.identifier || `wall-${index}`;
      activeIds.add(wallId);

      const width = Math.max(Number(wall.dimensions?.width ?? 0.1), 0.1);
      const height = Math.max(Number(wall.dimensions?.height ?? 2.4), 0.1);
      const length = Math.max(Number(wall.dimensions?.length ?? 0.05), 0.05);

      const geometry = new THREE.BoxGeometry(width, height, length);
      const material = materialRef.current ?? new THREE.MeshStandardMaterial({ color: 0x9fb8ff });

      let mesh = meshes.get(wallId);
      if (mesh) {
        mesh.geometry.dispose();
        mesh.geometry = geometry;
      } else {
        mesh = new THREE.Mesh(geometry, material);
        meshes.set(wallId, mesh);
        scene.add(mesh);
      }

      if (wall.transform && wall.transform.length === 16) {
        const m = wall.transform;
        mesh.matrix.set(
          m[0], m[4], m[8], m[12],
          m[1], m[5], m[9], m[13],
          m[2], m[6], m[10], m[14],
          m[3], m[7], m[11], m[15]
        );
        mesh.matrixAutoUpdate = false;
      } else {
        mesh.matrixAutoUpdate = true;
      }
    });

    meshes.forEach((mesh, id) => {
      if (!activeIds.has(id)) {
        scene.remove(mesh);
        mesh.geometry.dispose();
        meshes.delete(id);
      }
    });

    if (!hasFitRef.current && meshes.size > 0 && cameraRef.current && controlsRef.current) {
      const box = new THREE.Box3();
      meshes.forEach(mesh => box.expandByObject(mesh));
      const center = box.getCenter(new THREE.Vector3());
      const size = box.getSize(new THREE.Vector3());
      const maxDim = Math.max(size.x, size.y, size.z);
      const distance = Math.max(maxDim * 1.6, 2.5);
      cameraRef.current.position.set(center.x + distance, center.y + distance * 0.7, center.z + distance);
      cameraRef.current.lookAt(center);
      controlsRef.current.target.copy(center);
      controlsRef.current.update();
      hasFitRef.current = true;
    }
  }, [walls]);

  return (
    <div
      ref={containerRef}
      className={className}
      style={{ width: '100%', height: '100%', minHeight: '400px' }}
    />
  );
}
