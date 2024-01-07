[toc]

# Css 原理



## 1. HTML 与 CSS 的三大原则



### 1.1 原则一：响应式的设计(Responsive design)

响应式设计，就是网页可以在所有屏幕尺寸上运行，例如 PC 端、Mobile 端 等。



遵循的原则：

1. **Fluid Layouts**: 流动式布局
    - 也称为**自适应布局**布局
    - 不使用像素，而是使用百分比来设计 页面布局

2. **Media Queries**: 媒体查询
    - 可以针对不同的媒体类型定义不同的样式
    - CSS3 中使用 `@media` 根据浏览器的不同尺寸定义不同的样式
3. **Responsive Images**: 响应式图片
    - 在不同的屏幕尺寸、分辨率或具有其他类似特性的设备上都呈现良好的图片
    - 带有 `srcset` 和 `sizes` 属性的响应式图片
4. **Correct Units**: 正确的单位
5. **Desktop first vs Mobile first**: 桌面优先 vs 移动端优先

### 1.2 原则二：可维护、可扩展的代码(Maintainable and scalable code)

对于开发者比较重要，编写可维护、可扩展的代码需要遵循的原则：

1. **Clean**：干净简洁
2. **Easy-to-understand**: 易于理解
3. **Growth**: 可以扩展
4. **Reusable**: 可以复用
5. **How to organize files**: 文件组织方式
6. **How to name classes**: 类的命名
7. **How to structure HTML**: HTML的结构



### 1.3 原则三：网站性能



提高网站的性能，须遵循的原则：

1. **Less HTTP requests**: 减少 HTTP 调用
2. **Less code**: 代码简介
3. **Compress code**: 代码的压缩
4. **Use a CSS preprocessor**: 使用 CSS 预处理器
5. **Less images**: 减少图片
6. **Compress images**: 图片的压缩



## 2. CSS 原理概述



### 

HTML 与 CSS 加载过程如下图：

![HTML与CSS加载过程](E:\notes\前端\pic\HTML与CSS加载过程.PNG)



整个过程如下：

1. 加载 HTML 页面
2. 解析 HTML 页面
    1. 生成 HTML 文档对象模型（DOM）
    2. 从 HTML 中加载 CSS 代码
        - 解析 CSS
            - 解决 CSS 的声明冲突（级联）
            - 生成最终的 CSS 值
    3. 生成 CSS 对象模型（CSSOM）
3. DOM 与 CSSOM 合并，生成 Render Tree（渲染树）
4. 使用 视觉格式化 模型，进行一些算法计算，例如 定位、浮动等
5. 渲染完成



### 2.1 Load CSS 过程详解

#### 2.1.1 CSS解析-级联(Cascade)与特异性(Specificity)



一条 CSS 的规则如下：

```css
.my-class {
    color: blue;
    text-align: center;
    font-size: 20px;
}
```

- .my-class - 选择器
- {} - 样式声明块
- font-size: 20px; - 声明语句



CSS 中的 C，即 **Cascade 级联**。这也是 CSS 解析中的第一步。

**Cascade 级联就是不同样式的合并过程，即当有多个 CSS 样式作用在同一个元素上时，解决冲突的过程**。

而解决冲突的过程就是优先级的排序。



有三种不同来源的 CSS 需要级联，分别是：

- Auther：开发人员定义的 CSS 样式
- User：用户使用浏览器更改 CSS 样式
- Browser（User Agent）：浏览器也会默认加载一些 CSS 样式



**cascade解析优先级顺序**

CSS 解析的优先级顺序如下图：

![CSS_cascade解析优先级顺序](E:\notes\前端\pic\CSS_cascade解析优先级顺序.PNG)



1. **IMPORTANCE**：对所有 CSS 样式有无 important属性进行排序
2. **SPECIFICITY**：选择器的特异性排序
3. **SOURCE ORDER**：CSS 源码的先后排序



##### 1. IMPORTANCE

首先对 CSS 样式种有无 important属性进行排序，排序遵循：

1. User `!important`: 用户在浏览器种定义的 `!important` 属性
2. Author `!important`: 开发作者在代码种定义的 `!important` 属性
3. Author: 开发作者代码定义
4. User：用户在浏览器中定义
5. Default Browser：浏览器默认定义



实例：

```css
.button {
    backgroud-color: blue !important;
}

#nav .button {
    backgroud-color: green;
}
```



可以看到，有 important 属性的肯定更重要，更优先。



如果 IMPORTANCE 相同，那么会进行下一步的判断

##### 2. SPECIFICITY（选择器的特异性）

SPECIFICITY（选择器的特异性）优先级考虑主要有以下几个要点：

1. **Inline style**：样式中的内联属性
2. **IDs**：ID 选择器
3. **Classes，pseudo-classes，attribute**：类选择器，伪类选择器，属性
4. **Elements，pseudo-elements**: 元素选择器(eg. div, img, a...)，伪元素选择器



如何根据上面四个要点进行特异性计算呢？

会根据 CSS 样式与选择器生成一个四元组，分别对应上面 1-4 个要点的计算个数的结果(inline, IDs, classes, Elements)，然后从左到右进行比较。



例如：

```css
.my-btn {
    backgroud-color: blue;
}

nav#nav div.pull-right .my-btn {
    backgroud-color: green;
}

a {
    backgroud-color: purple;
}

#nav a.my-btn:hover {
    backgroud-color: yellow;
}
```

上面四个样式的计算结果分别是：

- (0,0,1,0) - 因为 my-btn 是一个类选择器，其他都是 0 
- (0,1,2,2) - 因为 #nav ，pull-right 与 my-btn 是 2 个类选择器，nav 与 div 是两个元素选择器

- (0,0,0,1) - a 是元素选择器

- (0,1,2,1) - #nav 是 IDs 选择器，my-btn 与 hover 是 2 个类选择器（hover是伪类），a 是原色选择器



从左到右依次比较得到：

(0,0,0,1) < (0,0,1,0) < (0,1,2,1) < (0,1,2,2)

最终，绿色胜出



如果此时，有相同的特异性，那么进行第三步。

##### 3. SOURCE ORDER(CSS 源码的顺序)

**在 CSS 代码中，最后一个声明的 样式 胜出**。



#### 2.1.2 CSS解析-值处理（Value Processing）

在 CSS 中定义了 vh、vm、rem 等这些单位的值时，最终都会被转换为像素 px。这就是只处理的过程（Value Processing）。



下面看一个示例，来理解整个过程：

![CSS_Value_Processing值处理](E:\notes\前端\pic\CSS_Value_Processing值处理.PNG)



整个 Value Processing 的过程如下：

1. width(paragraph)
    - **Declared value**: 代码中两处有 paragraph width，一处是 p 元素选择器的 140px，一处是 amazing 类选择器的 66%
    - **Cascade value**：级联过程，p 元素选择低于 amazing 的类选择器，因此为 66%
    - **Specified value**(默认值)：因为有了 Cascade 级联结果，因此默认值就是 66%
    - **Computed value**(相对的单位转换为像素): 66% 百分号不是一个单位，因此不处理
    - **Used Value**(对上一步的值进行最终的计算): 66% 是相对其父元素，也就是 section 中定义的 width 为 280px，结算结果为 280px * 66% = 184.8px
    - **Actual value**(实际值，四舍五入)：四舍五入后为 185px
2. padding(paragraph)
    - **Declared value**: 代码中没有定义
    - **Cascade value**：没有级联过程
    - **Specified value**(默认值)：CSS 对于没有定义的样式，都有一个默认值，这里 padding 的默认值为 0px
    - **Computed value**(相对的单位转换为像素): 已经是 0px 无需计算
    - **Used Value**(对上一步的值进行最终的计算): 已经是 0px 无需计算
    - **Actual value**(实际值，四舍五入)：已经是 0px 无需计算
3. font-size(root)
    - **Declared value**: 代码中没有定义
    - **Cascade value**：浏览器默认的 font-size 为 16px
    - **Specified value**(默认值)：因为有了 Cascade 级联结果，因此默认值就是 16px
    - **Computed value**(相对的单位转换为像素): 已经是 16px 无需计算
    - **Used Value**(对上一步的值进行最终的计算): 已经是 16px 无需计算
    - **Actual value**(实际值，四舍五入)：已经是 16px 无需计算
4. font-size(section)
    - **Declared value**: 代码中 section 类选择器定义了 font-size 为 1.5rem
    - **Cascade value**：没有其他冲突的样式，因此级联过程就为 1.5rem
    - **Specified value**(默认值)：因为有了 Cascade 级联结果，因此默认值就是 1.5rem
    - **Computed value**(相对的单位转换为像素): 1.5rem 是相对单位，因此需要转换，这里的相对其实是对于其父元素，也就是 font-size(root) 属性为 16px，1.5rem就是 1.5 * 16px = 24px
    - **Used Value**(对上一步的值进行最终的计算): 已经是 24px 无需计算
    - **Actual value**(实际值，四舍五入)：已经是 24px 无需计算
5. font-size(paragraph)
    - **Declared value**: 代码中没有定义
    - **Cascade value**：没有级联过程
    - **Specified value**(默认值)：默认值继承自父元素，也就是 font-size(section) 属性为 24px，这里也就是继承为 24px
    - **Computed value**(相对的单位转换为像素): 已经是 24px 无需计算
    - **Used Value**(对上一步的值进行最终的计算): 已经是 24px 无需计算
    - **Actual value**(实际值，四舍五入)：已经是 24px 无需计算





上面的 Computed Value 就是将相对单位(eg. rem...)，转换为绝对像素 px，那么这是如何实现的？Used Value 如何将具有比例的值转换绝对像素的？

下面是一个例子，虽然 % 不是一个相对单位，为了理解，这里把他比作一个相对单位。

这里注意几个单位：

- %：相对于父元素
- em：相对于父元素的大小，如当前对文本的字体尺寸未被人为设置，则相对于浏览器的默认字体尺寸。
    - **子元素字体大小的em是相对于<u>父元素</u>字体大小**
    - **元素的width/height/padding/margin用em的话是相对于<u>该元素</u>的font-size**
- rem：相对的只是HTML**根元素的字体大小**
- vh：相对于视窗高度的单位，1vh=1/100浏览器高度。
- vw：相对于视窗宽度的单位，1vw=1/100浏览器宽度。
- em、rem、vh、vw 都是为了响应式布局应运而生。

![CSS相对单位转为绝对像素](E:\notes\前端\pic\CSS相对单位转为绝对像素.PNG)

详细说明：

- %(fonts): header 的 font-size 为 150px，<u>%相对于其父元素</u>，也就是 body 的 font-size，结果为 150% * 16px = 24px
- %(lengths): .header-child 的 padding 为 10%，<u>%相对于其父元素</u>，也就是 header 的 width，结果为 10% * 1000px = 100px
- em(font): .header-child 的 font-size 为 3em，<u>em 表示字体大小时，相对于其父元素</u>，也就是 .header 的 font-size，结果为 3em * 24px = 72px
- em(lengths): header 的 padding 为 2em，em <u>表示width/height/padding/margin时，相对于当前元素的字体大小</u>，也就是 header 自己的 font-size，结果为 2em * 24px = 48px
- rem: header 的 marigin-bottom 为 10rem，<u>rem 相对于根元素的字体大小</u> ，也就是 body 的 font-size，结果为 10rem * 16px = 160px



#### 2.1.3 INHERITANCE(继承)

![css_inheritance](E:\notes\前端\pic\css_inheritance继承.PNG)



继承就是子元素继承父元素的样式，注意，只有具有继承属性的样式才可以向下传递。

1. 是否存在级联，如果有级联，则 Specified value 就是级联的结果
2. 如果没有级联，判断属性是否具有继承属性
    1. 如果具有继承属性，Specified value 就是其父元素的值
    2. 如果没有继承属性，Specified value 就是默认值



###  2.2 CSS Render Website(渲染过程)



The Visual Format Model：可视化模型

CSS 视觉格式化模型（*visual formatting model）*是用来处理盒子box模型，与布局的计算规则，渲染文档树种的每个元素，以确定最后的布局。



视觉格式化模型会根据**CSS 盒子模型**将文档中的元素转换为一个个盒子，每个盒子的布局由以下因素决定：

- **盒子的尺寸**：精确指定、由约束条件指定或没有指定
- **盒子的类型**：行内盒子（inline）、行内级盒子（inline-level）、原子行内级盒子（atomic inline-level）、块盒子（block）
- **定位方案**（positioning scheme）：普通流定位、浮动定位或绝对定位
- 文档树中的其它元素：即当前盒子的子元素或兄弟元素
- **视口**尺寸与位置
- 所包含的图片的尺寸
- 其他的某些外部因素



该模型会根据盒子的包含**块（containing block）**的边界来渲染盒子。通常，盒子会创建一个包含其后代元素的包含块，但是盒子并不由包含块所限制，当盒子的布局跑到包含块的外面时称为溢出（*overflow）*。



#### 盒子模型

![盒子模型](E:\notes\前端\pic\css盒子模型.PNG)

- pading: 内边距
- margin：外边距
- content：text、image 等盒子的内容
- width：宽度
- height：高度
- border：盒子的边框



**盒子 width 和 height 的计算**：

- `total width = right border + right padding + specified width + left padding + left border`
- `total height = top border + top padding + specified height + bottom padding + bottom border`

例如，设置 width 为 10%，又设置了 border 和 padding 的大小，那么实际的宽度应该是，10% + padding + border



上面的计算公式适用于 `border-sizing: content-box` 也是默认的配置。



如果 `boder-sizing: border-box`,那么 盒子 width 和 height 的计算公式如下：

- `total width = specified width`
- `total height = specified height`

例如，设置 width 为 10%，又设置了 border 和 padding 的大小，那么实际的宽度还是 10%，但由于设置了 border 和 padding，实际的内容区变小了。





#### 盒子类型

display 属性设置元素：

- **block**：  此元素将显示为块级元素

    - 默认情况下，dispaly：none，就是不显示
    - block 块总是占用 100% width
    - 此元素前后会带有换行符，也就是垂直排列
    - 高度，行高以及顶和底边距都可控制

    ```css
    display: block
    
    display: flex
    display: table
    display: list-item
    ```

    

    

- **inline**： 默认。此元素会被显示为内联元素

    - 元素前后没有换行符。也就是内联元素是水平排列的。
    - 并且只会占用其内容的大小，宽度就是它的文字或图片的宽度，不可改变。
    - 高，行高及顶和底边距不可改变；
    - padding 和 margin 只在水平方向生效（左右）

    ```css
    display: inline
    ```

    

- **inline-block**：

    - 变成 块级元素，但是只占用内容的大小。
    - 元素既具有 block 元素可以设置宽高的特性，同时又具有 inline 元素默认不换行的特性。

    ```css
    display: inline-box
    ```

    

#### 盒子定位



定位有下面几种：

- `position: static`: static(正常定位) 是元素position属性的默认值，包含此属性的元素遵循常规流。
- `position: relative`: relative(相对定位) 。
    - 原来在标准流的位置继续占有
    - 元素在移动位置的时候，是相对于自己原来的位置
- `position: absolute`：absolute（绝对定位）。
    - 相对于上一个相对定位的块
    - 原先块不占位置
    - relative（相对定位）并没有脱离文档流，而absolute（绝对定位）脱离了文档流；
    - relative（相对定位）相对于自身在常规流中的位置进行偏移定位，而absolute（绝对定位）相对于离自身最近的定位祖先元素的位置进行偏移定位。
- `position: fixed`: fixed（固定定位）
    - absolute（绝对定位）相对于定位祖先元素进行偏移定位，而fixed（固定定位）相对于窗口进行偏移定位；
    - absolute（绝对定位）的定位祖先元素可以是相对定位的元素，而fixed（固定定位）的定位祖先元素只能是**窗口**。



#### 堆叠顺序

使用 z-index 样式。在三维坐标系的盒模型中，用z-index来表示元素在z轴叠加顺序上的上下关系，z-index值较大的元素将叠加在z-index值较小的元素上。

