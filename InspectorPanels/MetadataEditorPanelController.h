/*
 *  Copyright (C) 2009 Stephen F. Booth <me@sbooth.org>
 *  All Rights Reserved
 */

#import <Cocoa/Cocoa.h>

@class ViewSelector;

// ========================================
// A HUD panel for editing the metadata of the selected tracks
// ========================================
@interface MetadataEditorPanelController : NSWindowController
{
	IBOutlet ViewSelector * _viewSelector;
@private
	id _inspectedDocument;
}

// ========================================
// Properties
@property (readonly, assign) id inspectedDocument;

// ========================================
// Action Methods
- (IBAction) toggleMetadataEditorPanel:(id)sender;

@end
