CUDA Path Tracer
================

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 3**

* David Li
* [LinkedIn](https://www.linkedin.com/in/david-li-15b83817b/)
* Tested on: Windows 10, Intel(R) Core(TM) i9-10980HK CPU @ 2.40GHz 32Gb, GTX 2070 Super (Personal Computer)

[Repo Link](https://github.com/theCollegeBoardOfc/Project3-CUDA-Path-Tracer)

### Why Path Trace?

The primary motivation behind path tracing is to properly render light in a scene. This is done essentially by shooting several rays into a scene, letting them bounce around and accumulate color. If however, this is only performed once, the render looks rather poor, thus we instead will repeat the process hundreds sometimes thousands of times and take an average of all those colors to yield a final sample. This takes a rather long time: an 800x800 resolution image would have 640000 pixels, we would shoot out at least one ray (sometimes more) per pixel for each sample, if we take 5000 samples, then the path tracer would be shooting out 3.2 billion rays. This rendered scene shoots out four times more rays than that.

![](img/angel.png)

This scene is rendered with around 1000 samples.

![](img/discus1.png)

### "Embarassingly Parallel"

Perhaps the one saving grace about all those rays is that much of the work in path tracing can be parallelized. The color accumulated by one ray does not depend on the color of another. The CPU can only parallelize a small quantity of processes, capped by number of cores on the CPU. The GPU on the other hand was designed for this kind of work. Thousands of processes can be run on the GPU at once, making that 3.2 billion figure a lot less daunting.

### Stream Compaction

Simply developing the path-tracer on the GPU rather the CPU yields an incredible increase in performance, but we can still do better. The first major step in improving performance is to do stream compaction on terminated rays. In order to properly simulate light, every single ray bounces around the scene until one of three termination conditions. 1. It hits a light. 2. It hits nothing. 3. It reaches its maxdepth. Hitting the max depth is the latest a ray will terminate. It's basically telling the ray, "Ok you've gone on long enough, time to just tell me what you have and move on." Going to max depth for a ray is the worst case scenario, we would much rather the ray not hit anything or hit a light, these are earlier termination conditions, and are the reason stream compaction works. For a single sample, here is the effects of stream compaction. 

![](img/chart1.png)

As the depth increases, we have to do less and less work because stream compaction is removing terminated rays. Also, note that there are zero rays at depth 8, this was the max depth, so all rays were terminated. The next chart compares a closed system and an open system. The open system has no wall behind the scene, meaning ray can terminate by bouncing out and hitting nothing. The closed system has a wall behind the scene, meaning any ray that would have bounced out are reflected back into the scene.

![](img/chart2.png)

As is likely expected: the closed system benefits much less from stream compaction. One of ray termination condtions, not hitting anything, will never be satisfied under the closed system. 

### Other performance "improvements"
Another "improvement" that was introduced was sorting by material type. In other words, when the rays intersect an object that object has a material type which encompasses objects color, emittance and how rays should bounce off it. If we sort by material type, then we leverage the architecture of the GPU to be more efficient. This is because processes or threads are executed in groups of 32: called a warp. If just one thread in a warp is running, then the other 31 threads just sit idle. By sorting by material, we minimize the chance of this sort of thing happening with the idea that rays with the same material type will do a similar amount of work and terminate at around the same time. Unfortunately, this did not really work out, on running a test scene, the FPS (frames per second) on the render dropped ever so slightly from a little over 4.0 to around 3.9. this is bad and is likely because the work of sorting by materials takes longer than the amount of time saved by the sorting. Another performance improvement that actually increased performance was caching the fist bounce. For every sample we take, the first ray intersection is almost always the same, so we can save this first bounce and reuse it. For the test scene this almost doubled the FPS from 4.0 to hovering around 6.0. Testing both at the same time gave an FPS of around 5.0. 
</br >
Here is the test scene for reference.


![](img/teapotbig.png)

### Depth of Field
Often times in photography, the camera can focus on a subject while making the background blurry. This effect is known as depth of field. There are two paramaters to consider when simulating this effect in a path tracer. Focal length and aperture. In layman's terms, focal length is how far away the in focus part should be, and aperture is how blurry the blurry part should be. The way we achieve this effect is actually quite simple. Every ray has an origin (a starting point) and a direction. What we can do is calculate the point on the ray's direction that would be at the focal length, then randomly jitter the origin based on the aperture, and lastly recalculate the new direction using the jittered origin to the point at the focal length. The intuition behind this is that if our intersection is at the focal length, our ray will be exactly the same. The further away the intersect is from the focal length, the more the new ray will be off from the old ray. If we compound this effect over thousands of samples, we get the depth of field effect. 
</br >
</br >
Following Render- Focal Length: 10. Aperture: 1. Notice the reflective sphere is crisp, and the scene get blurrier when further away from it.
![](img/df0.png)
</br >
</br >
Following Render- Focal Length: 7. Aperture: 1. Focal Length decreased and now the sharper part of the image is closer.
![](img/df1.png)
</br >
</br >
Following Render- Focal Length: 15. Aperture: 1. Focal Length increased and now the sharper part of the image is at the back wall.
![](img/df2.png)
</br >
</br >
Following Render- Focal Length: 10. Aperture: .2 Focal length is 10 so the reflective sphere is in focus. Note that the aperture is very small, that means we move the ray origin very little and get very little blurring.
![](img/df4.png)
</br >
</br >
Following Render- Focal Length: 10. Aperture: 3 Increasing the apperture makes the blurry parts much blurrier.
![](img/df5.png)
</br >
</br >
Admittedly, getting this to work took a lot longer than it should have. 
![](img/DepthOfFieldFail.PNG)
</br >
</br >
This pile of mess occured because I was not properly changing my random numbers. The random number generator I was using requires a seed. This seed is generated using a number of inputs, one of them being a pixel index. Instead of indexing every pixel uniquely. I indexed using x and y. This means pixels that share the same row and column were getting the same random number. Hence all those lines. After figuring this one out, I stumbled upon this. 
![](img/dof1.png)
</br >
</br >
This happens because I was till caching the first bounce. Meaning the ray was shooting into the exact same spot for every sample. 

### Anti-Aliasing
[Paul Bourke](http://paulbourke.net/miscellaneous/raytracing/) provides a great explaination of this. Basically, the goal is to create smoother transistions between pixels. We do this by shooting more than one ray per pixel, randomly offseting their origins, and averaging their colors at the end. Using anti-aliasing takes quite a bit longer as the pathtracer has four times as many rays to work with as before.
</br >
</br >
Here is a render without anti-aliasing.
![](img/aano.png)
</br >
</br >
Here is a render with anti-aliasing
![](img/aayes.png)
</br >
</br >
Frankly, I cannot see a difference. I suspect that it has to do with the random offset being too small. That being said, it certainly looks better than this.
</br >
![](img/tvstoppedworking.PNG)
</br >
</br >
This happens when the buffer sizes are not properly adjusted to accomodate for all the extra rays.

### OBJ Loading
OBJ files basically encode 3d objects. [TinyObjLoader](https://github.com/tinyobjloader/tinyobjloader) was used to load the files into the path tracer. The objects in these files basically consist of a lot of planes bound by control points, normally called faces. When checking to see if a ray intersects an object, we have to iterate through every single thing in the scene. For simple scenes this is fine, but once we load in an obj the number of things in the scene can blow up. Each face in the loaded object is a new thing to check intersections against. Considering objects can have tens of thousands of faces, one can imagine that this can slow down the path tracer quite a bit. One simple performance improvement is to introduce a bounding box which encapsulates the entire object. Before we check against all the faces in an object, we first check against the bounding box. If we don't intersect with it, then we don't have to check any of the faces. Potentially saving a lot of useless work. 

</br >
</br >
Here is a comparison between objects of differing complexities. Each object was rendered in a scene with and without a bounding box and timed to 100 samples.

![](img/chart3.png)

</br >
</br >
The objects of middle and most complexity both experienced around a 10% reduction in runtime. The use of a bounding box is much less noticable for the low complexity object. This is quite expectd. As the bounding box is saving more work of higher complexity objects. What perhaps is more interesting though, is comparing the effects of having and not having the bounding box, on the same object at different scale factors.

![](img/chart4.png)
</br >
For reference: This is the object when scaled by twice it's size (last column)
![](img/teapotbig.png)
</br >
and this is the object when scaled by .25 it's size (first column)
![](img/teapotsmall.png)
</br >
When the object is small, we are saving significantly more time than if the same object was big. Much fewer rays would intersect the small object, so keeping the majority or rays from checking against it is quite significant. On the other hand, the majority of rays would intersect the big object anyway, so using the bounding box doesn't save as much time. 

### Restartable Path-tracer
Despite all the performance improvements, the path tracer could still take hours to render an image. It is thus beneficial to be able to stop the execution, and pick up from where was left off upon running the pather tracer again, rather than need to restart the whole process. One may also want to adjust paramaters or make small adjustments to the scene while not fully restarting. While running the path tracer, one can press 'x' on their keyboard to save the current state of the execution. When launching the path tracer, one has the option to load the most recently saved state and pick up from there. This isn't really a performance or aesthetic improvement, but a quality of life one. Here is the feature in action
![](img/restart.gif)
</br >
</br >
One pretty interesting unintentional consequence of this feature is the ability to save a render state, load a different scene, and then load the render state. From this we can get interesting renders like this one
</br >
![](img/RestartFail.PNG)
</br >
This was actually a bug caused by an indexing error, but the thought still stands.

### References
</br >

[Angel Obj](https://www.cgtrader.com/free-3d-models/character/fantasy-character/lucy-a-christian-angel-statue-bb54169c38f87b1130bf72bfa18b3d9c)

</br >

[Discus Thrower Obj](https://www.turbosquid.com/3d-models/free-obj-mode-sculpture-discobolus-discus-thrower/1093054)

</br >

[Teapot Obj](https://graphics.stanford.edu/courses/cs148-10-summer/as3/code/as3/teapot.obj)

</br >

[Cube Obj](https://gist.github.com/MaikKlein/0b6d6bb58772c13593d0a0add6004c1c)

</br >

[Paul Bourke Anti-Aliasing](http://paulbourke.net/miscellaneous/raytracing/)

</br >

[TinyObjLoader](https://github.com/tinyobjloader/tinyobjloader)

</br >

[PBRT](https://pbr-book.org/3ed-2018/contents)
