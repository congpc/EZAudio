//
//  EZAudioPlot.m
//  EZAudio
//
//  Created by Syed Haris Ali on 9/2/13.
//  Copyright (c) 2013 Syed Haris Ali. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "EZAudioPlot.h"
#import "EZAudioDisplayLink.h"

//------------------------------------------------------------------------------
#pragma mark - Structures
//------------------------------------------------------------------------------

typedef struct
{
    float            *buffer;
    int               bufferSize;
    TPCircularBuffer  circularBuffer;
} EZAudioPlotHistoryInfo;

//------------------------------------------------------------------------------
#pragma mark - Types
//------------------------------------------------------------------------------

#if TARGET_OS_IPHONE
typedef CGRect EZRect;
#elif TARGET_OS_MAC
typedef NSRect EZRect;
#endif

//------------------------------------------------------------------------------
#pragma mark - EZAudioPlot
//------------------------------------------------------------------------------

@interface EZAudioPlot () <EZAudioDisplayLinkDelegate>
@property (nonatomic, strong) EZAudioDisplayLink *displayLink;
@property (nonatomic, assign) EZAudioPlotHistoryInfo *historyInfo;
@property (nonatomic, assign) CGPoint *points;
@property (nonatomic, assign) UInt32 pointCount;
@end

@implementation EZAudioPlot

//------------------------------------------------------------------------------
#pragma mark - Dealloc
//------------------------------------------------------------------------------

- (void)dealloc
{
    TPCircularBufferCleanup(&self.historyInfo->circularBuffer);
    free(self.historyInfo);
    free(self.points);
}

//------------------------------------------------------------------------------
#pragma mark - Initialization
//------------------------------------------------------------------------------

- (id)init
{
    self = [super init];
    if (self)
    {
        [self initPlot];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self)
    {
        [self initPlot];
    }
    return self;
}

#if TARGET_OS_IPHONE
- (id)initWithFrame:(CGRect)frameRect
#elif TARGET_OS_MAC
- (id)initWithFrame:(NSRect)frameRect
#endif
{
    self = [super initWithFrame:frameRect];
    if (self)
    {
        [self initPlot];
    }
    return self;
}

#if TARGET_OS_IPHONE
- (void)layoutSubviews
{
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.waveformLayer.frame = self.bounds;
    [self redraw];
    [CATransaction commit];
}
#elif TARGET_OS_MAC
- (void)layout
{
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.waveformLayer.frame = self.bounds;
    [self redraw];
    [CATransaction commit];
}
#endif

- (void)initPlot
{
    self.centerYAxis = YES;
    self.optimizeForRealtimePlot = YES;
    self.gain = 1.0;
    self.plotType = EZPlotTypeRolling;
    self.shouldMirror = NO;
    self.shouldFill = NO;
    
    // Setup history window
    self.historyInfo = (EZAudioPlotHistoryInfo *)malloc(sizeof(EZAudioPlotHistoryInfo));
    self.historyInfo->bufferSize = kEZAudioPlotDefaultHistoryBufferLength;
    self.historyInfo->buffer = calloc(self.rollingHistoryLength, sizeof(float));
    TPCircularBufferInit(&self.historyInfo->circularBuffer, kEZAudioPlotDefaultHistoryBufferLength);
    
    self.waveformLayer = [CAShapeLayer layer];
    self.waveformLayer.frame = self.bounds; // TODO: account for resizing view
    self.waveformLayer.lineWidth = 0.5f;
    self.waveformLayer.fillColor = nil;
    self.waveformLayer.backgroundColor = nil;
    
    self.points = calloc(kEZAudioPlotMaxHistoryBufferLength, sizeof(CGPoint));
    self.pointCount = 0;
#if TARGET_OS_IPHONE
    self.color = [UIColor colorWithHue:0 saturation:1.0 brightness:1.0 alpha:1.0];
#elif TARGET_OS_MAC
    self.color = [NSColor colorWithCalibratedHue:0 saturation:1.0 brightness:1.0 alpha:1.0];
    self.wantsLayer = YES;
#endif
    self.backgroundColor = nil;
    [self.layer addSublayer:self.waveformLayer];
}

//------------------------------------------------------------------------------
#pragma mark - Setters
//------------------------------------------------------------------------------

- (void)setBackgroundColor:(id)backgroundColor
{
    [super setBackgroundColor:backgroundColor];
    self.layer.backgroundColor = [backgroundColor CGColor];
}

//------------------------------------------------------------------------------

- (void)setColor:(id)color
{
    [super setColor:color];
    self.waveformLayer.strokeColor = [color CGColor];
    if (self.shouldFill)
    {
        self.waveformLayer.fillColor = [color CGColor];
    }
}

//------------------------------------------------------------------------------

- (void)setOptimizeForRealtimePlot:(BOOL)optimizeForRealtimePlot
{
    _optimizeForRealtimePlot = optimizeForRealtimePlot;
    if (optimizeForRealtimePlot && !self.displayLink)
    {
        self.displayLink = [EZAudioDisplayLink displayLinkWithDelegate:self];
    }
    optimizeForRealtimePlot ? [self.displayLink start] : [self.displayLink stop];
}

//------------------------------------------------------------------------------

- (void)setShouldFill:(BOOL)shouldFill
{
    [super setShouldFill:shouldFill];
    self.waveformLayer.fillColor = shouldFill ? [self.color CGColor] : nil;
}

//------------------------------------------------------------------------------
#pragma mark - Drawing
//------------------------------------------------------------------------------

- (void)redraw
{
    EZRect frame = [self.waveformLayer frame];
    if (self.pointCount > 0)
    {
        CGMutablePathRef path = CGPathCreateMutable();
        double xscale = (frame.size.width) / (float)self.pointCount;
        double halfHeight = floor(frame.size.height / 2.0);
        int deviceOriginFlipped = 1;
        CGAffineTransform xf = CGAffineTransformIdentity;
        CGFloat translateY = !self.centerYAxis ?: halfHeight + frame.origin.y;
        xf = CGAffineTransformTranslate(xf, 0.0, translateY);
        xf = CGAffineTransformScale(xf, xscale, deviceOriginFlipped * halfHeight);
        CGPathAddLines(path, &xf, self.points, self.pointCount);
        if (self.shouldMirror)
        {
            xf = CGAffineTransformScale(xf, 1.0f, -1.0f);
            CGPathAddLines(path, &xf, self.points, self.pointCount);
        }
        if (self.shouldFill)
        {
            CGPathCloseSubpath(path);
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.waveformLayer.path = path;
        [CATransaction commit];
        CGPathRelease(path);
    }
}

//------------------------------------------------------------------------------
#pragma mark - Update
//------------------------------------------------------------------------------

- (void)updateBuffer:(float *)buffer withBufferSize:(UInt32)bufferSize
{
    // update the scroll history datasource
    float rms = [EZAudioUtilities RMS:buffer length:bufferSize];
    float src[1];
    src[0] = rms == NAN ? 0.0 : rms;
    TPCircularBufferProduceBytes(&self.historyInfo->circularBuffer, src, sizeof(src));

    int32_t targetBytes = self.rollingHistoryLength * sizeof(float);
    int32_t availableBytes = 0;
    float *historyBuffer = TPCircularBufferTail(&self.historyInfo->circularBuffer, &availableBytes);
    int32_t bytes = MIN(targetBytes, availableBytes);
    memcpy(self.historyInfo->buffer, historyBuffer, bytes);
    if (targetBytes <= availableBytes)
    {
        TPCircularBufferConsume(&self.historyInfo->circularBuffer, sizeof(src));
    }
    
    // copy samples
    switch (self.plotType)
    {
        case EZPlotTypeBuffer:
            [self setSampleData:buffer
                         length:bufferSize];
            break;
        case EZPlotTypeRolling:
            
            [self setSampleData:self.historyInfo->buffer
                         length:self.historyInfo->bufferSize];
            break;
        default:
            break;
    }
    
    // update drawing
    if (!self.optimizeForRealtimePlot)
    {
        [self redraw];
    }
}

//------------------------------------------------------------------------------

- (void)setSampleData:(float *)data length:(int)length
{
    // append to buffer type
    CGPoint *points = self.points;
    for (int i = 0; i < length; i++)
    {
        points[i].x = i;
        points[i].y = data[i] * self.gain;
    }
    points[0].y = points[length - 1].y = 0.0f;
    self.pointCount = length;
}

//------------------------------------------------------------------------------
#pragma mark - Adjusting History Resolution
//------------------------------------------------------------------------------

- (int)rollingHistoryLength
{
    return self.historyInfo->bufferSize;
}

//------------------------------------------------------------------------------

- (int)setRollingHistoryLength:(int)historyLength
{
    self.historyInfo->bufferSize = MIN(kEZAudioPlotMaxHistoryBufferLength, historyLength);
    return self.historyInfo->bufferSize;
}

//------------------------------------------------------------------------------
#pragma mark - EZAudioDisplayLinkDelegate
//------------------------------------------------------------------------------

- (void)displayLinkNeedsDisplay:(EZAudioDisplayLink *)displayLink
{
    [self redraw];
}

//------------------------------------------------------------------------------

@end