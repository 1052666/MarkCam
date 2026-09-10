#import <UIKit/UIKit.h>
#import "CameraViewController.h"
@interface AppDelegate:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
 self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.window.tintColor=[UIColor colorWithRed:.48 green:.92 blue:.78 alpha:1];self.window.rootViewController=[CameraViewController new];[self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char *argv[]){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}}
