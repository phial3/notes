[toc]



# memcache



## 原理

内存无非是两种，一种是<u>预先分配</u>，一种是<u>动态分配</u>。

动态分配从效率的角度来讲相对来说要慢点，因为它需要实时的去分配内存使用，但是这种方式的好处就是可以节约内存使用空间



memcached 采用的是**预先分配的原则**，这种方式是拿空间换时间的方式来提高它的速度，会造成不能很高效的利用内存空间

memcached 采用了 **Slab Allocation** 机制<u>来解决内存碎片的问题</u>，Slab Allocation的*<u>基本原理就是按照预先规定的大小，将分配的内存分割成特定长度的块，并把尺寸相同的块分成组（chunk的集合）</u>*。









### Slab Allocation



Slab Allocator 的基本原理是按照预先规定的大小,将分配的内存分割成特定长度的块，也就是 chunk，并把尺寸相同的块分成组(chunk 的集合 slab class).

slab allocator 还有重复使用已分配的内存的目的。也就是说,分配到的内存不会释放,而是重复利用。

![memcache_slab_allocator](E:\notes\work\memcache\images\memcache-slab-allocator.png)



Slab Allocation 的主要术语

- **Page**
    - 分配给 Slab 的内存空间, 默认是 1MB。
- **Slab**
    - 切分的标准
    - 之后会根据 slab 的大小切分成 chunk。
- **Chunk**
    - 用于缓存记录的内存空间。
    - 实际数据存储的内存空间
- **Slab Class**
    - 特定大小的 chunk 的组。





memcached 根据收到的数据的大小，选择最适合数据大小的 slab class。

memcached 中保存着 slab class 内空闲 chunk 的列表, 根据该列表选择 chunk,然后将数据缓存于其中。

![memcache_slab_select](E:\notes\work\memcache\images\memcache-slab-select.png)



memcached会针对客户端发送的数据选择slab并缓存到chunk中.

这样就有一个弊端那就是比如要缓存的数据大小是100个字节，如果被分配到如上图112字节的chunk中的时候就造成了12个字节的浪费，虽然在内存中不会存在碎片，但是也造成了内存的浪费，这也是拿空间换时间，不过memcached对于分配到的内存不会释放，而是重复利用。



<u>**默认情况下chunk是1.25倍的增加的**</u>，当然也可以自己通过-f设置，这种内部的分割算法可以参看源码下的slabs.c文件。



## memcache 存储过程



**Memcache单进程最大可开的内存是2GB**，如果想缓存更多的数据，建议还是开辟更多的memcache进程（不同端口）或者使用分布式memcache进行缓存，将数据缓存到不同的物理机或者虚拟机上。





Slab下面可不直接就是存储区域片（就是chunks）了。而是page。

如果一个新的缓存数据要被存放，memcached首先选择一个合适的slab，然后查看该slab是否还有空闲的chunk

1. 如果有则直接存放进去；
2. 如果没有则要进行申请。



slab申请内存时以 page 为单位，所以在放入第一个数据，无论大小为多少，都会有 1M 大小的 page 被分配给该 slab。

申请到 page 后，slab 会将这个 page 的内存按 chunk 的大小进行切分，这样就变成了一个chunk的数组，在从这个chunk数组中选择一个用于存储数据



在缓存的清除方面，memcache是不释放已分配内存。当已分配的内存所在的记录失效后，这段以往的内存空间，memcache自然会重复利用起来。至于过期的方式，也是采取get到此段内存数据的时候采取查询时间戳，看是否已经超时失效。基本不会有其他线程干预数据的生命周期







Memcached在启动时通过**-m参数**指定最大使用内存，但是这个不会一启动就占用完，而是逐步分配给各slab的。

- 如果一个新的数据要被存放，首先选择一个合适的slab，然后查看该slab是否还有空闲的chunk，如果有则直接存放进去；
- 如果没有则要进行申请，slab申请内存时以page为单位，无论大小为多少，都会有1M大小的page被分配给该slab（该page不会被回收或者重新分配，永远都属于该slab）。申请到page后，slab会将这个page的内存按chunk的大小进行切分，这样就变成了一个chunk的数组，再从这个chunk数组中选择一个用于存储数据。若没有空闲的page的时候，则会对改slab进行LRU，而不是对整个memcache进行LRU。





## LRU



stats 状态参数



https://github.com/memcached/memcached/blob/master/doc/protocol.txt
