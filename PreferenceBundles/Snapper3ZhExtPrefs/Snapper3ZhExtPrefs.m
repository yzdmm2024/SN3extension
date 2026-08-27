@interface PSListController : UIViewController
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)setSpecifiers:(NSArray *)specifiers;
- (void)reloadSpecifiers;
@property (nonatomic, retain, readonly) NSArray *specifiers;
@property (nonatomic, retain, readonly) UITableView *tableView;
@end

@interface Snapper3ZhExtPrefsController : PSListController
@end

@implementation Snapper3ZhExtPrefsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SN3延伸板";
    // 手动加载 Root.plist 中的 specifiers
    NSArray *s = [self loadSpecifiersFromPlistName:@"Root" target:self];
    if (s.count) {
        [self setSpecifiers:s];
        [self.tableView reloadData];
    }
}

@end