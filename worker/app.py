"""
FastAPI service performing incremental TSDF integration using Open3D
"""
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import open3d as o3d
import numpy as np
import json
import os
import threading
from pathlib import Path
from PIL import Image
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = FastAPI(title="Room Scan TSDF Worker", version="1.0.0")

# CORS middleware
app.add_middleware(
    CORSMiddleware, 
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# TSDF session state per token
class TSDFSession:
    def __init__(self, token: str):
        self.token = token
        self.tsdf_volume = None
        self.voxel_length = 0.02
        self.sdf_trunc = 0.08
        self.color_type = o3d.pipelines.integration.TSDFVolumeColorType.RGB8
        self.lock = threading.Lock()
        self.frame_count = 0
        self.chunk_count = 0
        
    def initialize_tsdf(self, volume_size: float = 3.0):
        """Initialize TSDF volume"""
        volume = o3d.pipelines.integration.ScalableTSDFVolume(
            voxel_length=self.voxel_length,
            sdf_trunc=self.sdf_trunc,
            color_type=self.color_type,
            volume_unit_resolution=16,
            depth_sampling_stride=1
        )
        self.tsdf_volume = volume
        logger.info(f"[{self.token[:8]}] TSDF volume initialized")
    
    def integrate_frame(self, rgbd_image: o3d.geometry.RGBDImage, 
                       intrinsic: o3d.camera.PinholeCameraIntrinsic,
                       extrinsic: np.ndarray):
        """Integrate a single frame into TSDF"""
        if self.tsdf_volume is None:
            self.initialize_tsdf()
        
        self.tsdf_volume.integrate(rgbd_image, intrinsic, extrinsic)
        self.frame_count += 1

# Global session storage with locks
sessions = {}
sessions_lock = threading.Lock()

def get_session(token: str) -> TSDFSession:
    """Get or create session for token"""
    with sessions_lock:
        if token not in sessions:
            sessions[token] = TSDFSession(token)
            logger.info(f"Created new session for token: {token[:8]}...")
        return sessions[token]

# Request models
class InitSessionRequest(BaseModel):
    token: str

class IngestChunkRequest(BaseModel):
    token: str
    chunkPath: str

class FinalizeRequest(BaseModel):
    token: str

def load_depth_image(depth_path: str, depth_scale: float) -> np.ndarray:
    """Load depth PNG as uint16 and convert to meters"""
    try:
        depth_img = Image.open(depth_path)
        depth_array = np.array(depth_img, dtype=np.uint16)
        depth_meters = depth_array.astype(np.float32) / depth_scale
        return depth_meters
    except Exception as e:
        logger.error(f"Failed to load depth image {depth_path}: {e}")
        raise

def load_color_image(color_path: str) -> np.ndarray:
    """Load color JPEG image"""
    try:
        color_img = Image.open(color_path)
        color_array = np.array(color_img)
        return color_array
    except Exception as e:
        logger.error(f"Failed to load color image {color_path}: {e}")
        raise

def load_meta_json(meta_path: str) -> dict:
    """Load metadata JSON file"""
    try:
        with open(meta_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Failed to load meta JSON {meta_path}: {e}")
        raise

def create_intrinsic_from_meta(meta: dict, use_depth_size: bool = True) -> o3d.camera.PinholeCameraIntrinsic:
    """Create PinholeCameraIntrinsic from metadata"""
    if use_depth_size and 'depthSize' in meta:
        width, height = meta['depthSize']
        # Try to get K_depth, fallback to scaling K_color
        if 'K_depth' in meta:
            K = np.array(meta['K_depth'])
        else:
            # Scale K_color to depth resolution
            K_color = np.array(meta['K_color'])
            color_w, color_h = meta['colorSize']
            scale_x = width / color_w
            scale_y = height / color_h
            K = K_color.copy()
            K[0, 0] *= scale_x  # fx
            K[1, 1] *= scale_y  # fy
            K[0, 2] *= scale_x  # cx
            K[1, 2] *= scale_y  # cy
    else:
        width, height = meta['colorSize']
        K = np.array(meta['K_color'])
    
    fx = K[0, 0]
    fy = K[1, 1]
    cx = K[0, 2]
    cy = K[1, 2]
    
    intrinsic = o3d.camera.PinholeCameraIntrinsic(
        width, height, fx, fy, cx, cy
    )
    return intrinsic

def get_world_to_camera_transform(T_wc_json: np.ndarray) -> np.ndarray:
    """
    Convert transform from JSON to Open3D format.
    Open3D TSDF integrate expects extrinsic as world-to-camera.
    Per spec: use T_cw = inverse(T_wc) where T_wc is from JSON.
    """
    # Open3D expects world-to-camera (extrinsic)
    # T_wc from JSON needs to be inverted to get world-to-camera
    T_cw = np.linalg.inv(T_wc_json)
    return T_cw

@app.get("/")
async def root():
    return {"message": "Room Scan TSDF Worker", "status": "running"}

@app.get("/health")
async def health():
    return {"status": "ok", "service": "tsdf-worker"}

@app.post("/init_session")
async def init_session(request: InitSessionRequest):
    """Initialize a new TSDF session for a token"""
    try:
        session = get_session(request.token)
        with session.lock:
            if session.tsdf_volume is None:
                session.initialize_tsdf()
            else:
                logger.info(f"[{request.token[:8]}] Session already initialized")
        
        return {
            "status": "ok",
            "token": request.token,
            "message": "Session initialized"
        }
    except Exception as e:
        logger.error(f"Error initializing session: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/ingest_chunk")
async def ingest_chunk(request: IngestChunkRequest):
    """Ingest a chunk of frames and integrate into TSDF"""
    chunk_path = Path(request.chunkPath)
    
    if not chunk_path.exists():
        raise HTTPException(status_code=404, detail=f"Chunk path does not exist: {request.chunkPath}")
    
    session = get_session(request.token)
    
    try:
        # Load index.json to get list of frame IDs
        index_path = chunk_path / "index.json"
        if not index_path.exists():
            raise HTTPException(status_code=400, detail="index.json not found in chunk")
        
        with open(index_path, 'r') as f:
            index_data = json.load(f)
        
        # Handle both list format and dict format
        if isinstance(index_data, list):
            frame_ids = index_data
        else:
            frame_ids = index_data.get('frames', [])
        
        if not frame_ids:
            logger.warning(f"[{request.token[:8]}] No frames in chunk index")
            return {"status": "ok", "frames_processed": 0, "message": "No frames to process"}
        
        logger.info(f"[{request.token[:8]}] Processing chunk with {len(frame_ids)} frames")
        
        frames_processed = 0
        frames_failed = 0
        
        with session.lock:
            # Process each frame
            for frame_id in frame_ids:
                try:
                    # Construct paths
                    rgb_path = chunk_path / "rgb" / f"{frame_id}.jpg"
                    depth_path = chunk_path / "depth" / f"{frame_id}.png"
                    meta_path = chunk_path / "meta" / f"{frame_id}.json"
                    
                    # Check if all files exist
                    if not rgb_path.exists():
                        logger.warning(f"[{request.token[:8]}] Missing RGB: {rgb_path}")
                        frames_failed += 1
                        continue
                    if not depth_path.exists():
                        logger.warning(f"[{request.token[:8]}] Missing depth: {depth_path}")
                        frames_failed += 1
                        continue
                    if not meta_path.exists():
                        logger.warning(f"[{request.token[:8]}] Missing meta: {meta_path}")
                        frames_failed += 1
                        continue
                    
                    # Load metadata
                    meta = load_meta_json(str(meta_path))
                    
                    # Load images
                    depth_meters = load_depth_image(str(depth_path), meta.get('depthScale', 1000.0))
                    color_array = load_color_image(str(rgb_path))
                    
                    # Create Open3D images
                    depth_o3d = o3d.geometry.Image((depth_meters * 1000).astype(np.uint16))
                    color_o3d = o3d.geometry.Image(color_array)
                    
                    # Create RGBD image
                    rgbd_image = o3d.geometry.RGBDImage.create_from_color_and_depth(
                        color_o3d,
                        depth_o3d,
                        depth_scale=1000.0,
                        depth_trunc=4.0,
                        convert_rgb_to_intensity=False
                    )
                    
                    # Create intrinsic
                    intrinsic = create_intrinsic_from_meta(meta, use_depth_size=True)
                    
                    # Get transform and convert to world-to-camera for Open3D
                    T_wc_json = np.array(meta['T_wc'])
                    T_cw = get_world_to_camera_transform(T_wc_json)
                    
                    # Integrate into TSDF
                    session.integrate_frame(rgbd_image, intrinsic, T_cw)
                    frames_processed += 1
                    
                except Exception as e:
                    logger.error(f"[{request.token[:8]}] Error processing frame {frame_id}: {e}")
                    frames_failed += 1
                    continue
            
            session.chunk_count += 1
            logger.info(f"[{request.token[:8]}] Chunk processed: {frames_processed} frames, {frames_failed} failed")
            
            # Optionally extract mesh after chunk (for preview)
            try:
                mesh = session.tsdf_volume.extract_triangle_mesh()
                mesh.compute_vertex_normals()
                
                # Write to latest.ply
                output_dir = Path(__file__).parent.parent / "laptop" / "server" / "data" / request.token / "mesh"
                output_dir.mkdir(parents=True, exist_ok=True)
                output_path = output_dir / "latest.ply"
                
                o3d.io.write_triangle_mesh(str(output_path), mesh)
                logger.info(f"[{request.token[:8]}] Updated latest.ply after chunk")
            except Exception as e:
                logger.warning(f"[{request.token[:8]}] Failed to extract mesh after chunk: {e}")
        
        return {
            "status": "ok",
            "token": request.token,
            "frames_processed": frames_processed,
            "frames_failed": frames_failed,
            "total_frames": session.frame_count
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error ingesting chunk: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/finalize")
async def finalize(request: FinalizeRequest):
    """Extract final triangle mesh and write to PLY file"""
    session = get_session(request.token)
    
    try:
        with session.lock:
            if session.tsdf_volume is None:
                raise HTTPException(status_code=400, detail="TSDF volume not initialized. Process chunks first.")
            
            logger.info(f"[{request.token[:8]}] Finalizing mesh extraction")
            
            # Extract triangle mesh
            mesh = session.tsdf_volume.extract_triangle_mesh()
            mesh.compute_vertex_normals()
            
            # Create output directory
            output_dir = Path(__file__).parent.parent / "laptop" / "server" / "data" / request.token / "mesh"
            output_dir.mkdir(parents=True, exist_ok=True)
            output_path = output_dir / "latest.ply"
            
            # Write PLY file
            success = o3d.io.write_triangle_mesh(str(output_path), mesh)
            
            if not success:
                raise HTTPException(status_code=500, detail="Failed to write PLY file")
            
            # Get mesh stats
            num_vertices = len(mesh.vertices)
            num_triangles = len(mesh.triangles)
            
            logger.info(f"[{request.token[:8]}] Mesh finalized: {num_vertices} vertices, {num_triangles} triangles")
            
            return {
                "status": "ok",
                "token": request.token,
                "mesh_path": str(output_path),
                "vertices": num_vertices,
                "triangles": num_triangles,
                "total_frames": session.frame_count
            }
            
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error finalizing mesh: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8090)
