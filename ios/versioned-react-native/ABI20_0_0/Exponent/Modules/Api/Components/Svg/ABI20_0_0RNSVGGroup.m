/**
 * Copyright (c) 2015-present, Horcrux.
 * All rights reserved.
 *
 * This source code is licensed under the MIT-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "ABI20_0_0RNSVGGroup.h"

@implementation ABI20_0_0RNSVGGroup

- (void)renderLayerTo:(CGContextRef)context
{
    [self clip:context];
    [self renderGroupTo:context];
}

- (void)renderGroupTo:(CGContextRef)context
{
    ABI20_0_0RNSVGSvgView* svg = [self getSvgView];
    [self traverseSubviews:^(ABI20_0_0RNSVGNode *node) {
        if (node.responsible && !svg.responsible) {
            svg.responsible = YES;
        }
        
        if ([node isKindOfClass:[ABI20_0_0RNSVGRenderable class]]) {
            [(ABI20_0_0RNSVGRenderable*)node mergeProperties:self];
        }
        
        [node renderTo:context];
        
        if ([node isKindOfClass:[ABI20_0_0RNSVGRenderable class]]) {
            [(ABI20_0_0RNSVGRenderable*)node resetProperties];
        }
        
        return YES;
    }];
}

- (void)renderPathTo:(CGContextRef)context
{
    [super renderLayerTo:context];
}

- (CGPathRef)getPath:(CGContextRef)context
{
    CGMutablePathRef __block path = CGPathCreateMutable();
    [self traverseSubviews:^(ABI20_0_0RNSVGNode *node) {
        CGAffineTransform transform = node.matrix;
        CGPathAddPath(path, &transform, [node getPath:context]);
        return YES;
    }];

    return (CGPathRef)CFAutorelease(path);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event withTransform:(CGAffineTransform)transform
{
    UIView *hitSelf = [super hitTest:point withEvent:event withTransform:transform];
    if (hitSelf) {
        return hitSelf;
    }
    
    CGAffineTransform matrix = CGAffineTransformConcat(self.matrix, transform);

    CGPathRef clip = [self getClipPath];
    if (clip) {
        CGPathRef transformedClipPath = CGPathCreateCopyByTransformingPath(clip, &matrix);
        BOOL insideClipPath = CGPathContainsPoint(clip, nil, point, self.clipRule == kRNSVGCGFCRuleEvenodd);
        CGPathRelease(transformedClipPath);
        
        if (!insideClipPath) {
            return nil;
        }
        
    }
    
    for (ABI20_0_0RNSVGNode *node in [self.subviews reverseObjectEnumerator]) {
        if (![node isKindOfClass:[ABI20_0_0RNSVGNode class]]) {
            continue;
        }
        
        if (event) {
            node.active = NO;
        } else if (node.active) {
            return node;
        }
        
        UIView *hitChild = [node hitTest: point withEvent:event withTransform:matrix];
        
        if (hitChild) {
            node.active = YES;
            return (node.responsible || (node != hitChild)) ? hitChild : self;
        }
    }
    return nil;
}

- (void)parseReference
{
    if (self.name) {
        ABI20_0_0RNSVGSvgView* svg = [self getSvgView];
        [svg defineTemplate:self templateName:self.name];
    }

    [self traverseSubviews:^(__kindof ABI20_0_0RNSVGNode *node) {
        [node parseReference];
        return YES;
    }];
}

- (void)resetProperties
{
    [self traverseSubviews:^(__kindof ABI20_0_0RNSVGNode *node) {
        if ([node isKindOfClass:[ABI20_0_0RNSVGRenderable class]]) {
            [(ABI20_0_0RNSVGRenderable*)node resetProperties];
        }
        return YES;
    }];
}

@end
