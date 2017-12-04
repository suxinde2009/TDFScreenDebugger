//
//  TDFSDARCollectionViewModel.h
//  Pods
//
//  Created by 开不了口的猫 on 2017/9/28.
//
//

#import <Foundation/Foundation.h>
#import "TDFALRequestModel.h"


@interface TDFSDARCollectionViewModel : NSObject

@property (nonatomic, strong) TDFALRequestModel *requestModel;
@property (nonatomic, assign, readonly) CGFloat cellHeight;
@property (nonatomic, assign, readonly) CGFloat cellWidth;

@end