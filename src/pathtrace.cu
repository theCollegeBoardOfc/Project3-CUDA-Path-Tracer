#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/count.h>
#include <thrust/sort.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1
#define SORTBYMATERIAL 1
#define CACHEFIRSTBOUNCE 0
#define ANTIALIASING 1
#define DEPTHOFFIELD 0
#define USEBOUNDINGBOX 0

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

struct rayTerminated
{
    __host__ __device__
        bool operator()(const PathSegment p)
    {
        return p.remainingBounces == 0;
    }
};

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3 * dev_image = NULL;
static PathSegment* dev_terminated_paths;
static Geom * dev_geoms = NULL;
static Geom* dev_faces = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
#if CACHEFIRSTBOUNCE
static ShadeableIntersection* dev_cached_intersections = NULL;
#endif
// TODO: static variables for device memory, any extra info you need, etc
// ...

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_faces, scene->faces.size() * sizeof(Geom));
	cudaMemcpy(dev_faces, scene->faces.data(), scene->faces.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);	

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	#if CACHEFIRSTBOUNCE
	cudaMalloc(&dev_cached_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_cached_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
	#endif

	#if ANTIALIASING
	#if CACHEFIRSTBOUNCE
	cudaMalloc(&dev_cached_intersections, 4 * pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_cached_intersections, 0, 4 * pixelcount * sizeof(ShadeableIntersection));
	#endif

	cudaMalloc(&dev_terminated_paths, 4 * pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_intersections, 4 * pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, 4 * pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_paths, 4 * pixelcount * sizeof(PathSegment));
	#else
	#if CACHEFIRSTBOUNCE
	cudaMalloc(&dev_cached_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_cached_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
	#endif
	cudaMalloc(&dev_terminated_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));
	#endif

	// TODO: initialize any extra device memeory you need

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_faces);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	cudaFree(dev_terminated_paths);
	#if CACHEFIRSTBOUNCE
	cudaFree(dev_cached_intersections);
	#endif
	// TODO: clean up any extra device memory you created

	checkCUDAError("pathtraceFree");
}

__host__ __device__ glm::vec2 ConcentricSampleDisk(const glm::vec2& u) {
	glm::vec2 uOffset = 2.f * u - glm::vec2(1, 1);

	if (uOffset.x == 0 && uOffset.y == 0) { 
		return glm::vec2(0, 0); 
	}
			
	float theta, r;
	if (std::abs(uOffset.x) > std::abs(uOffset.y)) {
		r = uOffset.x;
		theta = PI / 4.f * (uOffset.y / uOffset.x);
	}
	else {
		r = uOffset.y;
		theta = PI / 2.f - PI / 4.f * (uOffset.x / uOffset.y);
	}
	return r * glm::vec2(std::cos(theta), std::sin(theta));

}
/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	thrust::uniform_real_distribution<float> u01(0, 1);
	thrust::uniform_real_distribution<float> u02(0, 1);
	#if ANTIALIASING
	if (x < cam.resolution.x && y < cam.resolution.y) {
		for (int i = 0; i < 4; i++) {
			int index = x + (y * cam.resolution.x);
			thrust::default_random_engine randomX = makeSeededRandomEngine(iter, index, i*2+1);
			thrust::default_random_engine randomY = makeSeededRandomEngine(iter, index, i*2+1);
			
			//PathSegment& segment = pathSegments[index+i];
			PathSegment& segment = pathSegments[4 * index + i];
			glm::vec2 offset = glm::vec2(u01(randomX), u01(randomY)) - glm::vec2(.5, .5);

			float distance = glm::length(offset);
			distance = glm::clamp(1 - distance, 0.f, 1.f);

			segment.aliasIdx = i;
			segment.ray.origin = cam.position +glm::vec3(offset.x * 4 * cam.pixelLength.x, offset.y * 4 * cam.pixelLength.y, 0);
			segment.color = glm::vec3(1.0f, 1.0f, 1.0f);// * distance;

			// TODO: implement antialiasing by jittering the ray
			segment.ray.direction = glm::normalize(cam.view
				- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
				- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
			);
			segment.pixelIndex = index;
			segment.remainingBounces = traceDepth;
			segment.remainingBounces = 8;
			#if DEPTHOFFIELD
			thrust::default_random_engine rngX = makeSeededRandomEngine(iter, index, 11);
			thrust::default_random_engine rngY = makeSeededRandomEngine(iter, index, 10);

			float lensRadius = 1;
			float focalDistance = 10.0;
			if (lensRadius > 0) {
				glm::vec2 pLens = lensRadius * ConcentricSampleDisk(glm::vec2(u01(rngX), u01(rngY)));

				float ft = fabs(focalDistance / segment.ray.direction.z);
				glm::vec3 pFocus = segment.ray.direction * (ft)+segment.ray.origin;

				segment.ray.origin += glm::vec3(pLens.x, pLens.y, 0);
				segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);

			}
			#endif
		}
	}
	#else 
	if (x < cam.resolution.x && y < cam.resolution.y) {

		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		// TODO: implement antialiasing by jittering the ray
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
		segment.remainingBounces = 8;
	#if DEPTHOFFIELD
		thrust::default_random_engine rngX = makeSeededRandomEngine(iter, index, 11);
		thrust::default_random_engine rngY = makeSeededRandomEngine(iter, index, 10);
		
		float lensRadius = 3;
		float focalDistance = 10;
		if (lensRadius > 0) {
			glm::vec2 pLens = lensRadius * ConcentricSampleDisk(glm::vec2(u01(rngX), u01(rngY)));

			float ft = fabs(focalDistance / segment.ray.direction.z);
			glm::vec3 pFocus = segment.ray.direction * (ft)+segment.ray.origin;

			segment.ray.origin += glm::vec3(pLens.x, pLens.y, 0);
			segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);

		}
	#endif
}
	#endif
	
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, Geom* faces
	, int geoms_size
	, int faces_size
	, ShadeableIntersection* intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == BOUNDINGBOX) {
#if USEBOUNDINGBOX
				int tbox = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				if (tbox > 0.0f) {
					for (int j = 0; j < faces_size; j++) {
						Geom& face = faces[j];
						t = planeIntersectionTest(face, pathSegment.ray, tmp_intersect, tmp_normal, outside);
						if (t > 0.0f && t_min > t)
						{
							t_min = t;
							hit_geom_index = i;
							intersect_point = tmp_intersect;
							normal = tmp_normal;
						}
					}
				}
#else
				for (int j = 0; j < faces_size; j++) {
					Geom& face = faces[j];
					t = planeIntersectionTest(face, pathSegment.ray, tmp_intersect, tmp_normal, outside);
					if (t > 0.0f && t_min > t)
					{
						t_min = t;
						hit_geom_index = i;
						intersect_point = tmp_intersect;
						normal = tmp_normal;
					}
				}
#endif
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

        if (hit_geom_index == -1)
        {
            intersections[path_index].t = -1.0f;
        }
        else
        {
            //The ray hits something
            intersections[path_index].t = t_min;
            intersections[path_index].materialId = geoms[hit_geom_index].materialid;
            intersections[path_index].surfaceNormal = normal;
            //This was newly added by me
            intersections[path_index].intersectPoint = intersect_point;
            intersections[path_index].hit_geom_index = hit_geom_index;
        }
    }
}


// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void sampleF (int iter
    , int num_paths
    , ShadeableIntersection* shadeableIntersections
    , PathSegment* pathSegments
    , Material* materials
    )
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < num_paths)
    {
        ShadeableIntersection intersection = shadeableIntersections[idx];
        if (intersection.t > 0.0f) {
            // if the intersection exists...
            Material material = materials[intersection.materialId];
            glm::vec3 materialColor = material.color;

            // If the material indicates that the object was a light, "light" the ray
            if (material.emittance > 0.0f) {
                pathSegments[idx].color *= (materialColor * material.emittance);
                pathSegments[idx].remainingBounces = 0;
            }
            // Otherwise, do some pseudo-lighting computation. This is actually more
            // like what you would expect from shading in a rasterizer like OpenGL.
            // TODO: replace this! you should be able to start with basically a one-liner
            else {
                //float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, pathSegments[idx].remainingBounces);
				scatterRay(pathSegments[idx], intersection.intersectPoint, intersection.surfaceNormal, material, rng);
				//pathSegments[idx].color *= shadeMaterial(iter, idx, intersection, pathSegments[idx], material);
                
                
                pathSegments[idx].remainingBounces--;
                //pathSegments[idx].color = intersection.surfaceNormal;
            }
            // If there was no intersection, color the ray black.
            // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
            // used for opacity, in which case they can indicate "no opacity".
            // This can be useful for post-processing and image compositing.
        }
        else {
			pathSegments[idx].color = glm::vec3(0.0, 0.0, 0.0);//glm::vec3(0.0f);
            pathSegments[idx].remainingBounces = 0;
        }
    }
}

__global__ void addTerminatedPaths(int nPaths, PathSegment* iterationPaths, PathSegment* terminatedPaths) {
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (index < nPaths) {
        PathSegment path = iterationPaths[index];
        if (path.remainingBounces <= 0) {
#if ANTIALIASING
			int alias = path.aliasIdx;
			terminatedPaths[4 * path.pixelIndex+alias] = path;
#else
			terminatedPaths[path.pixelIndex] = path;
#endif         
        }
    }
}
__global__ void TerminateAll(int nPaths, PathSegment* iterationPaths, PathSegment* terminatedPaths) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < nPaths) {
		PathSegment path = iterationPaths[index];
#if ANTIALIASING
		int alias = path.aliasIdx;
		terminatedPaths[4 * path.pixelIndex + alias] = path;
#else
		terminatedPaths[path.pixelIndex] = path;
#endif    
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < nPaths)
	{
	#if ANTIALIASING
		index *= 4;
		/*PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
		return;*/
		glm::vec3 color = glm::vec3(0, 0, 0);
		for (int i = 0; i < 4; i++) {
			PathSegment iterationPath = iterationPaths[index+i];
			color += iterationPath.color;
			float x = color.x;
			float y = color.y;
			float z = color.z;
		}
		color /= 4;
		image[iterationPaths[index].pixelIndex] += color;
	#else
	
	PathSegment iterationPath = iterationPaths[index];
	image[iterationPath.pixelIndex] += iterationPath.color;
	
	#endif
	}
}

struct matSort {
	__host__ __device__
		bool operator()(const ShadeableIntersection& a, const ShadeableIntersection& b) {
		return a.materialId > b.materialId;
	}
};

/*
OctTree Notes :
Octree takes form of a buffer- something like: 
*/


/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {

	
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	if (hst_scene->state.usingSavedState) {
		cudaMemcpy(dev_image, hst_scene->state.image.data(),
			pixelcount * sizeof(glm::vec3), cudaMemcpyHostToDevice);
	}

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");
	
	int depth = 0;
#if ANTIALIASING
	PathSegment* dev_path_end = dev_paths + pixelcount * 4;
	int copySize = pixelcount * 4;
#else
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int copySize = pixelcount;
#endif
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

    bool iterationComplete = false;
    while (!iterationComplete) {

        // clean shading chunks
        cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;

	#if CACHEFIRSTBOUNCE
		if ((iter == 1 || hst_scene->state.usingSavedState) && depth == 0) {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, dev_faces
				, hst_scene->geoms.size()
				, hst_scene->faces.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
			cudaMemcpy(dev_cached_intersections, dev_intersections,
				copySize * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}
		else if (iter > 1 && depth == 0) {
			cudaMemcpy(dev_intersections, dev_cached_intersections,
				copySize * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}
		else {
			dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, dev_faces
				, hst_scene->geoms.size()
				, hst_scene->faces.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
		}
	#else 
        // tracing
        
        computeIntersections <<<numblocksPathSegmentTracing, blockSize1d>>> (
            depth
            , num_paths
            , dev_paths
            , dev_geoms
			, dev_faces
            , hst_scene->geoms.size()
			, hst_scene->faces.size()
            , dev_intersections
            );
        checkCUDAError("trace one bounce");
        cudaDeviceSynchronize();
	#endif
        depth++;

		
        thrust::device_ptr<PathSegment> dev_thrust_path(dev_paths);
        thrust::device_ptr<ShadeableIntersection> dev_thrust_intersections(dev_intersections);
#if SORTBYMATERIAL 
		thrust::sort_by_key(dev_thrust_intersections, dev_thrust_intersections + num_paths
			               , dev_thrust_path, matSort());
		#endif

        // TODO:
        // --- Shading Stage ---
        // Shade path segments based on intersections and generate new rays by
        // evaluating the BSDF.
        // Start off with just a big kernel that handles all the different
        // materials you have in the scenefile.
        // TODO: compare between directly shading the path segments and shading
        // path segments that have been reshuffled to be contiguous in memory.

        sampleF <<<numblocksPathSegmentTracing, blockSize1d>>> (
          iter,
          num_paths,
          dev_intersections,
          dev_paths,
          dev_materials
		);

        addTerminatedPaths << <numblocksPathSegmentTracing, blockSize1d >> > (
            num_paths,
            dev_paths,
            dev_terminated_paths
            );

		if (depth > traceDepth) {
			TerminateAll << <numblocksPathSegmentTracing, blockSize1d >> > (
				num_paths,
				dev_paths,
				dev_terminated_paths
				);
			break;
		}
		/*ShadeableIntersection* debugIntersect = new ShadeableIntersection[pixelcount];
		PathSegment* debugPath = new PathSegment[pixelcount];
		Geom* debugGeom = new Geom[pixelcount];
		cudaMemcpy(debugIntersect, dev_intersections,
			pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToHost);
		cudaMemcpy(debugPath, dev_paths,
			pixelcount * sizeof(PathSegment), cudaMemcpyDeviceToHost);
		cudaMemcpy(debugGeom, dev_geoms,
			pixelcount * sizeof(Geom), cudaMemcpyDeviceToHost);
		std::cout << "_______________________________" << std::endl;
		for (int i = 0; i < num_paths-400; i += 400) {

			std::cout << "Terminated: " << debugPath[i].remainingBounces << std::endl;
			Ray r = debugPath[i].ray;
			std::cout << "Next: " << r.direction.x << " " << r.direction.y << " " << r.direction.z << std::endl;

		}
		delete[] debugIntersect;
		delete[] debugPath;
		delete[] debugGeom;*/

        int terminatedPaths = thrust::count_if(dev_thrust_path, dev_thrust_path + num_paths, rayTerminated());
        thrust::remove_if(dev_thrust_path, dev_thrust_path + num_paths, rayTerminated());
        num_paths -= terminatedPaths;
        if (num_paths <= 0) {
            iterationComplete = true; // TODO: should be based off stream compaction results.
        }
        if (guiData != NULL)
    		{
    			guiData->TracedDepth = depth;
    		}
		hst_scene->state.usingSavedState = false;
    }

    // Assemble this iteration and apply it to the image
    dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
    finalGather<<<numBlocksPixels, blockSize1d>>>(pixelcount, dev_image, dev_terminated_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
