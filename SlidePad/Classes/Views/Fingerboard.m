/*
 Copyright (c) 2012, Richard Eakin

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and
 the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and
 the following disclaimer in the documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
 WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
 ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 */

#import "PolyPatchController.h"
#import "PdBase.h"
#import "Fingerboard.h"
#import "TouchDiamond.h"
#import "PdFile.h"

#define RECEIVER_FREQ @"synth-freq"
#define RECEIVER_MAG @"synth-mag"

#define DEFAULT_SHARP_NOTES_COLOR [UIColor colorWithRed:0.0 green:0.5 blue:0.5 alpha:1.0]
#define DEFAULT_OTHER_NOTES_COLOR [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0]

static const CGFloat kThresholdForTouchRelease = 0.0;

@interface Fingerboard ()

@property (nonatomic, retain) NSMutableDictionary *touches;
@property (nonatomic, retain) TouchDiamond *monoTouch;

@property (nonatomic, retain) NSArray *voiceHighlights; // when quantizePitch == YES, this contains UIView's for highlighting the current touches

- (CGFloat)mapXToPitch:(CGFloat)x; // minPitch mapped to x = 0, maxPitch to x = self.frame.size.width
- (CGFloat)mapYToMag:(CGFloat)y; // y is flipped so the top of the view (origin) = full magnitude, while bottom = 0

- (void)sendParamsOff;
- (void)sendParamsOffForVoice:(int)voice;
- (void)sendParamsWithPoint: (CGPoint)point voice:(int)voice;
- (BOOL)pointIsWithinBounds:(CGPoint)point;
- (void)highlightVoices;
- (float)noteWidth;
- (NSArray *)highlightsArray;

@end


@implementation Fingerboard

@synthesize touches = touches_;
@synthesize monoTouch = monoTouch_;

@synthesize minPitch = minPitch_;
@synthesize maxPitch = maxPitch_;
@synthesize numNotes = numNotes_;
@synthesize numVoices = numVoices_;
@synthesize drawNoteLabels = drawNoteLabels_;
@synthesize quantizePitch = quantizePitch_;

@synthesize sharpNoteColor = sharpNoteColor_;
@synthesize touchColor = touchColor_;

@synthesize polyPatchController = polyPatchController_;

#pragma mark - Setup

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.multipleTouchEnabled = YES;
        
        self.minPitch = 36.0; 
        self.maxPitch = 60.0;
        self.numVoices = 1; // FIXME: it is still multi pitched..
        self.numNotes = self.maxPitch - self.minPitch;
        
        self.drawNoteLabels = YES;
		self.clipsToBounds = YES;
        self.backgroundColor = DEFAULT_OTHER_NOTES_COLOR;
        self.sharpNoteColor = DEFAULT_SHARP_NOTES_COLOR;
        self.touchColor = [UIColor redColor];
        
        self.layer.borderColor = self.sharpNoteColor.CGColor;
        self.layer.borderWidth = 2.0;

        self.touches = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    self.touches = nil;
    self.monoTouch = nil;
    self.sharpNoteColor = nil;
    self.touchColor = nil;
    [super dealloc];
}

#pragma mark - Public

- (void)updateAllVoices {
    for (TouchDiamond *diamond in [self.touches allValues]) {
        [self sendParamsWithPoint:diamond.center voice:diamond.touchIndex];
    }
}

- (void)mute {
	[self sendParamsOff];
}

- (void)reset {
    if (self.monoTouch) {
        [self.monoTouch removeFromSuperview];
        self.monoTouch = nil;
    } else {
		for (TouchDiamond *diamond in self.touches) {
			[diamond removeFromSuperview];
		}
	}

    [self.touches removeAllObjects];
    [self sendParamsOff];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    
    CGContextRef context = UIGraphicsGetCurrentContext();

    float nNotes = [self numNotes];
    float noteWidth = [self noteWidth];
    
    // ***** create a layer for sharp notes *****
    CGRect noteRect = CGRectMake(0.0, 0.0, noteWidth, CGRectGetHeight(self.bounds));
    CGLayerRef noteLayer = CGLayerCreateWithContext (context, noteRect.size, NULL);
    CGContextRef noteContext = CGLayerGetContext (noteLayer);
    CGContextSetFillColorWithColor(noteContext, self.sharpNoteColor.CGColor);
    CGContextFillRect(noteContext, noteRect);
    
    // ***** create a layer for line notes (C's and F's).  *****
    CGLayerRef lineLayer = CGLayerCreateWithContext (context, noteRect.size, NULL);
    CGContextRef lineContext = CGLayerGetContext (lineLayer);
    CGContextSetStrokeColorWithColor(lineContext, self.sharpNoteColor.CGColor);
    CGContextBeginPath(lineContext);
    CGContextMoveToPoint(lineContext, 0.0, 0.0);
    CGContextAddLineToPoint(lineContext, 0.0, noteRect.size.height);
    CGContextClosePath(lineContext);
    CGContextStrokePath(lineContext);
    
    
    // ***** set up text for midi number *****

	const float kTextColorGrayLevel = 0.75;
    CGContextSelectFont (context, "Helvetica", 12, kCGEncodingMacRoman);
    CGContextSetRGBFillColor(context, kTextColorGrayLevel, kTextColorGrayLevel, kTextColorGrayLevel, 1.0);
    CGContextSetTextDrawingMode (context, kCGTextFill); 
    CGAffineTransform textFlip = CGAffineTransformMake(1.0,0.0, 0.0, -1.0, 0.0, 0.0);
    CGContextSetTextMatrix(context, textFlip);
    
    
    int nm, ns;
    CGPoint notePoint = CGPointZero;
     
    for (int n = 0; n < nNotes; n++) {
        ns = n + self.minPitch;
        nm = ns % 12;
        if (nm == 1 || nm == 3 || nm == 6 || nm == 8 || nm == 10) {
            notePoint.x = n * noteWidth;
            CGContextDrawLayerAtPoint (context, notePoint, noteLayer);
        }            
        else if (nm == 0 || nm == 5) {
            notePoint.x = n * noteWidth;
            CGContextDrawLayerAtPoint (context, notePoint, lineLayer);
        }
        if (self.drawNoteLabels) {
            NSString *noteLabel = [NSString stringWithFormat:@"%d", ns];
            CGContextShowTextAtPoint (context, 
                                      n * noteWidth + 3.0, 
                                      self.bounds.size.height - 4.0,
                                      [noteLabel UTF8String], 
                                      [noteLabel length]); 
        }
    }
}

#pragma mark - Touches

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    CGPoint point;
    TouchDiamond *diamond;
    for (UITouch* touch in touches) {
        point = [touch locationInView:self];
        diamond = [[[TouchDiamond alloc] initWithIndex:[self.touches count]] autorelease];
        diamond.center = point;
        
        // if mono, add all diamonds to the touches array, but only 1 will be displayed
        // if poly, only add touches up to numVoices amount
        if (self.numVoices == 1) {
            [self.touches setObject:diamond forKey:[NSValue valueWithPointer:touch] ];
        } else if ([self.touches count] < self.numVoices) {
            [self.touches setObject:diamond forKey:[NSValue valueWithPointer:touch] ];
            [self addSubview:diamond];
            [diamond displayAnimated];
        }
		[self sendParamsWithPoint:point voice:diamond.touchIndex];
    }
    
    // if mono, use new touch as the position
    if (self.numVoices == 1) {
        // monoTouch is displayed, but update it's center and touchIndex to match the diamond
        if (self.monoTouch) {
            [self.monoTouch removeFromSuperview];
            self.monoTouch = nil;
        }
        self.monoTouch = diamond;
        [self addSubview:self.monoTouch];
        [self.monoTouch displayAnimated];
        
        [self sendParamsWithPoint:point voice:0];
    }

	if (self.quantizePitch) {
		[self highlightVoices];
	}
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    for (UITouch* touch in touches) {
        CGPoint point = [touch locationInView:self];
		if (![self pointIsWithinBounds:point]) {
            // TODO: turn off voice and remove the diamond
			return;
		}
        TouchDiamond *diamond = [self.touches objectForKey:[NSValue valueWithPointer:touch]];
        if (diamond) {
            diamond.center = point; // it won't always exist if we are in poly and the touch is being ignored
        }
        if (self.numVoices == 1 && diamond == self.monoTouch) {
            [self sendParamsWithPoint:point voice:0];
        } else if ([self.touches count] <= self.numVoices) {
			int dzero = [self.polyPatchController dollarZeroForInstance:diamond.touchIndex];
			[self sendParamsWithPoint:point voice:diamond.touchIndex];
		}
    }
	if (self.quantizePitch) {
		[self highlightVoices];
	}
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (self.numVoices == 1) {
        for (UITouch* touch in touches) {
            TouchDiamond *diamond = [self.touches objectForKey:[NSValue valueWithPointer:touch]];
            [self.touches removeObjectForKey:[NSValue valueWithPointer:touch]];
            if (diamond == self.monoTouch) {
                if ([self.touches count] == 0) {
                    [diamond removeFromSuperview];
                    [self sendParamsOff];
                }
                else {
                    // assign monoTouch to diamond with greatest index
                    NSInteger ii = 0;
                    int touchIndex;
                    TouchDiamond *newestTouch;
                    for (UITouch *t in self.touches) {
                        TouchDiamond *d = [self.touches objectForKey:t];
                        if (d.touchIndex > ii) {
                            ii = d.touchIndex;
                            newestTouch = d;
                        }
                    }
                    [self.monoTouch removeFromSuperview];
                    self.monoTouch = newestTouch;
                    [self addSubview:self.monoTouch];
                    [self sendParamsWithPoint:self.monoTouch.center voice:0];
                }
            } else {
			}

        }
    }
    else {
        for (UITouch* touch in touches) {
            TouchDiamond *diamond = [self.touches objectForKey:[NSValue valueWithPointer:touch]];

			int dzero = [self.polyPatchController dollarZeroForInstance:diamond.touchIndex];
			[self sendParamsOffForVoice:diamond.touchIndex];
			
            [diamond removeFromSuperview];
            [self.touches removeObjectForKey:[NSValue valueWithPointer:touch]];
        }
    }

	if (self.quantizePitch) {
		[self highlightVoices];
	}
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    RLog(@"************ touches cancelled ***************");
    if (self.numVoices == 1) {
        if (self.monoTouch) {
            [self.monoTouch removeFromSuperview];
            self.monoTouch = nil;
        }
        [self sendParamsOff];
    }
    else {
        for (UITouch* touch in touches) {
            TouchDiamond *diamond = [self.touches objectForKey:[NSValue valueWithPointer:touch]];
            [diamond removeFromSuperview];
            [self.touches removeObjectForKey:[NSValue valueWithPointer:touch]];
        }
    }

	if (self.quantizePitch) {
		[self highlightVoices];
	}
}

#pragma mark - Mapping functions

- (void)sendParamsWithPoint:(CGPoint)point voice:(int)voice {
    float pitch = self.minPitch + (self.maxPitch - self.minPitch) * point.x / CGRectGetWidth(self.frame);

	if (self.quantizePitch) {
		pitch = floorf(pitch);
	}

    float mag = (CGRectGetHeight(self.frame) - point.y) / CGRectGetHeight(self.frame);
	
	int dzero = [self.polyPatchController dollarZeroForInstance:voice];
	NSString *magReceiver = [NSString stringWithFormat:@"%d-%@", dzero, RECEIVER_MAG];
	NSString *pitchReceiver = [NSString stringWithFormat:@"%d-%@", dzero, RECEIVER_FREQ];

    [PdBase sendFloat:mag toReceiver:magReceiver];
    [PdBase sendFloat:pitch toReceiver:pitchReceiver];
}

- (void)sendParamsOffForVoice:(int)voice {
	int dzero = [self.polyPatchController dollarZeroForInstance:voice];
	NSString *magReceiver = [NSString stringWithFormat:@"%d-%@", dzero, RECEIVER_MAG];
	[PdBase sendFloat:0 toReceiver:magReceiver];	
}

- (void)sendParamsOff{
	for (PdFile *pd in [self.polyPatchController patches]) {
		NSString *magReceiver = [NSString stringWithFormat:@"%d-%@", [pd dollarZero], RECEIVER_MAG];
		[PdBase sendFloat:0 toReceiver:magReceiver];
	}
}

- (CGFloat)mapXToPitch:(CGFloat)x {
    float w = CGRectGetWidth(self.frame);

    float sx = self.minPitch + (self.maxPitch - self.minPitch) * x / w;
    return sx;
}

- (CGFloat)mapYToMag:(CGFloat)y {
    float h = CGRectGetHeight(self.frame);
    return (h - y) / h; 
}

#pragma mark - Overridden Accessors

- (void)setQuantizePitch:(BOOL)quantizePitch {
	if (quantizePitch_ != quantizePitch) {
		quantizePitch_  = quantizePitch;
		if (quantizePitch) {
			self.voiceHighlights = [self highlightsArray];
		} else {
			for (UIView *highlight in self.voiceHighlights) {
				[highlight removeFromSuperview];
			}
			self.voiceHighlights = nil;
		}
	}
}

#pragma mark - Private

- (void)highlightVoices {
	int i = 0;
	float noteWidth = [self noteWidth];
	for (TouchDiamond *voice in [self.touches allValues]) {
		UIView *highlight = [self.voiceHighlights objectAtIndex:i++];
		CGRect highlightFrame = highlight.frame;
		float touchX = voice.center.x;
		touchX -= fmod(touchX,noteWidth);
		highlightFrame.origin.x = touchX;
		highlightFrame.size.width = noteWidth;
		highlight.frame = highlightFrame;

		highlight.alpha = MAX(0.2, 0.67 - voice.center.y / self.frame.size.height); // alpha range: [0.2:0.67]
		highlight.hidden = NO;
	}
	while (i < self.numVoices) {
		UIView *highlight = [self.voiceHighlights objectAtIndex:i++];
		highlight.hidden = YES;
	}
}

- (BOOL)pointIsWithinBounds:(CGPoint)point {
	if (point.x < -kThresholdForTouchRelease || point.x > self.bounds.size.width + kThresholdForTouchRelease || 
		point.y < -kThresholdForTouchRelease || point.y > self.bounds.size.height + kThresholdForTouchRelease) {
		return NO;
	} else {
		return YES;
	}
}

- (float)noteWidth {
	return self.frame.size.width / [self numNotes];
}

- (NSArray *)highlightsArray {
	NSMutableArray *highlights = [NSMutableArray array];
	float noteWidth = [self noteWidth];
	float noteHeight = self.frame.size.height;
	for (int i = 0; i < self.numVoices; i++) {
		UIView *highlight = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, noteWidth, noteHeight)];
		highlight.backgroundColor = [UIColor whiteColor];
		highlight.hidden = YES;
		[self insertSubview:highlight atIndex:0]; // note: this is not efficient, since it shuffles the subviews many times - would be better to create a container for these highlights that resides below TouchDiamonds
		[highlights addObject:highlight];
	}
	return highlights;
}

@end
