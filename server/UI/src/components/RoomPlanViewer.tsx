import { useEffect, useRef } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

interface RoomPlanDimensions {
  width?: number;
  height?: number;
  length?: number;
}

interface RoomPlanSurface {
  identifier?: string;
  transform?: number[];
  dimensions?: RoomPlanDimensions;
}

interface RoomPlanObject extends RoomPlanSurface {
  category?: string;
}

interface RoomPlanViewerProps {
  walls: RoomPlanSurface[];
  doors: RoomPlanSurface[];
  windows: RoomPlanSurface[];
  objects: RoomPlanObject[];
  className?: string;
}

export default function RoomPlanViewer({ walls, doors, windows, objects, className = '' }: RoomPlanViewerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const sceneRef = useRef<THREE.Scene | null>(null);
  const rendererRef = useRef<THREE.WebGLRenderer | null>(null);
  const cameraRef = useRef<THREE.PerspectiveCamera | null>(null);
  const controlsRef = useRef<OrbitControls | null>(null);
  const meshesRef = useRef<Map<string, THREE.Mesh>>(new Map());
  const animationFrameRef = useRef<number | null>(null);
  const hasFitRef = useRef(false);
  const materialsRef = useRef<Map<string, THREE.MeshStandardMaterial>>(new Map());

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
      materialsRef.current.forEach(material => material.dispose());
      materialsRef.current.clear();
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
    const materials = materialsRef.current;
    const activeIds = new Set<string>();

    const getMaterial = (key: string, color: number, opacity = 0.9, transparent = false) => {
      const existing = materials.get(key);
      if (existing) return existing;
      const material = new THREE.MeshStandardMaterial({
        color,
        metalness: 0.05,
        roughness: 0.6,
        opacity,
        transparent,
      });
      materials.set(key, material);
      return material;
    };

    const normalizeDimension = (value: number | undefined, fallback: number) =>
      Math.max(Number(value ?? fallback), 0.05);

    const applyTransform = (mesh: THREE.Mesh, transform?: number[]) => {
      if (transform && transform.length === 16) {
        const m = transform;
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
    };

    const updateBox = (
      id: string,
      dimensions: RoomPlanDimensions | undefined,
      transform: number[] | undefined,
      material: THREE.MeshStandardMaterial
    ) => {
      activeIds.add(id);
      const width = normalizeDimension(dimensions?.width, 0.1);
      const height = normalizeDimension(dimensions?.height, 2.4);
      const length = normalizeDimension(dimensions?.length, 0.05);
      const geometry = new THREE.BoxGeometry(width, height, length);

      let mesh = meshes.get(id);
      if (mesh) {
        mesh.geometry.dispose();
        mesh.geometry = geometry;
        mesh.material = material;
      } else {
        mesh = new THREE.Mesh(geometry, material);
        meshes.set(id, mesh);
        scene.add(mesh);
      }

      applyTransform(mesh, transform);
    };

    if (walls.length + doors.length + windows.length + objects.length === 0) {
      hasFitRef.current = false;
    }

    walls.forEach((wall, index) => {
      const id = `wall-${wall.identifier ?? index}`;
      updateBox(id, wall.dimensions, wall.transform, getMaterial('wall', 0x9fb8ff, 0.9, true));
    });

    doors.forEach((door, index) => {
      const id = `door-${door.identifier ?? index}`;
      updateBox(id, door.dimensions, door.transform, getMaterial('door', 0xf2b05c, 0.9, true));
    });

    windows.forEach((windowItem, index) => {
      const id = `window-${windowItem.identifier ?? index}`;
      updateBox(id, windowItem.dimensions, windowItem.transform, getMaterial('window', 0x5cc8ff, 0.5, true));
    });

    objects.forEach((object, index) => {
      const id = `object-${object.identifier ?? index}`;
      const category = (object.category || 'object').toLowerCase();
      const colorMap: Record<string, number> = {
        chair: 0xb483ff,
        table: 0x8fd175,
        sofa: 0xff9f6e,
        bed: 0x7ab7ff,
        storage: 0xf2d05c,
        cabinet: 0xf2d05c,
        sink: 0x76d1c4,
        toilet: 0x76d1c4,
      };
      const color = colorMap[category] ?? 0xd9d9d9;
      updateBox(id, object.dimensions, object.transform, getMaterial(`object-${category}`, color, 0.85, true));
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
  }, [walls, doors, windows, objects]);

  return (
    <div
      ref={containerRef}
      className={className}
      style={{ width: '100%', height: '100%', minHeight: '400px' }}
    />
  );
}
