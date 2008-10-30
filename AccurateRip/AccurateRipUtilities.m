/*
 *  Copyright (C) 2007 - 2008 Stephen F. Booth <me@sbooth.org>
 *  All Rights Reserved
 */

#import "AccurateRipUtilities.h"
#import "CDDAUtilities.h"

#include <AudioToolbox/AudioFile.h>
#include <IOKit/storage/IOCDTypes.h>

// ========================================
// Calculate the AccurateRip checksum for the file at path
// ========================================
uint32_t 
calculateAccurateRipChecksumForFile(NSURL *fileURL, BOOL firstTrack, BOOL lastTrack)
{
	NSCParameterAssert(nil != fileURL);
	
	uint32_t checksum = 0;

	// Open the file for reading
	AudioFileID file = NULL;
	OSStatus status = AudioFileOpenURL((CFURLRef)fileURL, fsRdPerm, kAudioFileWAVEType, &file);
	if(noErr != status)
		return 0;
	
	// Verify the file contains CDDA audio
	AudioStreamBasicDescription fileFormat;
	UInt32 dataSize = sizeof(fileFormat);
	status = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &dataSize, &fileFormat);
	if(noErr != status)
		goto cleanup;
	
	if(!streamDescriptionIsCDDA(&fileFormat))
		goto cleanup;
	
	// Determine the total number of audio packets (frames) in the file
	UInt64 totalPackets;
	dataSize = sizeof(totalPackets);
	status = AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &dataSize, &totalPackets);
	if(noErr != status)
		goto cleanup;
	
	// Convert the number of frames to the number of blocks (CDDA sectors)
	NSUInteger totalBlocks = (NSUInteger)(totalPackets / AUDIO_FRAMES_PER_CDDA_SECTOR);
	NSUInteger blockNumber = 0;

	// Set up extraction buffers
	int8_t buffer [kCDSectorSizeCDDA];
	
	// Iteratively process each CDDA sector in the file
	for(;;) {
		
		UInt32 byteCount = kCDSectorSizeCDDA;
		UInt32 packetCount = AUDIO_FRAMES_PER_CDDA_SECTOR;
		SInt64 startingPacket = blockNumber * AUDIO_FRAMES_PER_CDDA_SECTOR;
		
		status = AudioFileReadPackets(file, false, &byteCount, NULL, startingPacket, &packetCount, buffer);
		
		if(noErr != status || kCDSectorSizeCDDA != byteCount || AUDIO_FRAMES_PER_CDDA_SECTOR != packetCount)
			break;
		
		checksum += calculateAccurateRipChecksumForBlock(buffer, blockNumber++, totalBlocks, firstTrack, lastTrack);
	}
	
cleanup:
	status = AudioFileClose(file);
/*	if(noErr != status)
		return 0;*/
	
	return checksum;
}

// ========================================
// Calculate the AccurateRip checksum for the specified range of CDDA sectors file at path
// ========================================
uint32_t 
calculateAccurateRipChecksumForFileRegion(NSURL *fileURL, NSUInteger firstSector, NSUInteger lastSector, BOOL firstTrack, BOOL lastTrack)
{
	return calculateAccurateRipChecksumForFileRegionUsingOffset(fileURL, firstSector, lastSector, firstTrack, lastTrack, 0);
}

uint32_t 
calculateAccurateRipChecksumForFileRegionUsingOffset(NSURL *fileURL, NSUInteger firstSector, NSUInteger lastSector, BOOL firstTrack, BOOL lastTrack, NSInteger readOffsetInFrames)
{
	NSCParameterAssert(nil != fileURL);
	NSCParameterAssert(lastSector >= firstSector);
	
	uint32_t checksum = 0;
	
	// Open the file for reading
	AudioFileID file = NULL;
	OSStatus status = AudioFileOpenURL((CFURLRef)fileURL, fsRdPerm, kAudioFileWAVEType, &file);
	if(noErr != status)
		return 0;
	
	// Verify the file contains CDDA audio
	AudioStreamBasicDescription fileFormat;
	UInt32 dataSize = sizeof(fileFormat);
	status = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &dataSize, &fileFormat);
	if(noErr != status)
		goto cleanup;
	
	if(!streamDescriptionIsCDDA(&fileFormat))
		goto cleanup;
	
	// Determine the total number of audio packets (frames) in the file
	UInt64 totalPacketsInFile;
	dataSize = sizeof(totalPacketsInFile);
	status = AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &dataSize, &totalPacketsInFile);
	if(noErr != status)
		goto cleanup;
	
	NSInteger totalSectorsInFile = (NSInteger)(totalPacketsInFile / AUDIO_FRAMES_PER_CDDA_SECTOR);
	
	// With no read offset, the range of sectors that will be read won't change
	NSInteger firstSectorToRead = firstSector;
	NSInteger lastSectorToRead = lastSector;

	// Negative read offsets can easily be transformed into positive read offsets
	// For example, suppose the desired range is sectors 10 through 20 and the read offset is -600 frames.
	// This is equivalent to requesting sectors 8 - 18 with a read offset of 576 frames
	while(0 > readOffsetInFrames) {
		readOffsetInFrames += AUDIO_FRAMES_PER_CDDA_SECTOR;
		--firstSectorToRead;
		--lastSectorToRead;
	}
	
	// readOffsetInSectors is the additional number of sectors that must be extracted (at the end) to ensure a 
	// complete sector will exist when the beginning of the read is adjusted by the read offset.
	// If this value is larger than one sector, one sector less than this should be skipped at the beginning.
	// For example, suppose the desired range is sectors 1 through 10 and the read offset is 600 frames.
	// In this case readOffsetInSectors will be 2, and the actual read should be from sectors 2 through 12, with the 
	// first 12 frames of sector 2 skipped and the last 12 frames of sector 12 skipped.
	NSUInteger readOffsetInSectors = (readOffsetInFrames +  (AUDIO_FRAMES_PER_CDDA_SECTOR - 1)) / AUDIO_FRAMES_PER_CDDA_SECTOR;
	NSUInteger readOffsetInBytes = 2 * sizeof(int16_t) * readOffsetInFrames;
	
	// Adjust the sectors for the read offset
	if(1 < readOffsetInSectors) {
		firstSectorToRead += readOffsetInSectors - 1;
		
		// Skipped whole sectors are taken into account above, so subtract them out here
		while(kCDSectorSizeCDDA > readOffsetInBytes)
			readOffsetInBytes -= kCDSectorSizeCDDA;
	}
	
	lastSectorToRead += readOffsetInSectors;

	// Clamp the read range to the range of audio contained in the file
	NSUInteger sectorsOfSilenceToPrepend = 0;
	if(0 > firstSectorToRead) {
		sectorsOfSilenceToPrepend = 0 - firstSectorToRead;
		firstSectorToRead = 0;
	}
	
	NSUInteger sectorsOfSilenceToAppend = 0;
	if(lastSectorToRead > totalSectorsInFile) {
		sectorsOfSilenceToAppend = lastSectorToRead - totalSectorsInFile;
		lastSectorToRead = totalSectorsInFile;
	}
	
	// The block range is inclusive, but should indicate the number of complete blocks to be read
	NSUInteger totalBlocks = lastSectorToRead - firstSectorToRead - readOffsetInSectors + 1;
	NSUInteger blockNumber = 0;
	
	int8_t buffer [kCDSectorSizeCDDA];

	// Prepend silence, if required
	// Since the AccurateRip checksum for silence is zero, all that must be accounted for is the block counter
	if(sectorsOfSilenceToPrepend)
		blockNumber += sectorsOfSilenceToPrepend;

	// Adjust the starting packet for the read offset
	SInt64 startingPacket = (firstSectorToRead * AUDIO_FRAMES_PER_CDDA_SECTOR) + readOffsetInFrames;
	
	// Iteratively process each CDDA sector in the file, adjusting each read for the specified read offset
	NSUInteger sectorCount = totalBlocks - (sectorsOfSilenceToPrepend + sectorsOfSilenceToAppend);
	while(sectorCount--) {
		
		UInt32 byteCount = kCDSectorSizeCDDA;
		UInt32 packetCount = AUDIO_FRAMES_PER_CDDA_SECTOR;
		
		status = AudioFileReadPackets(file, false, &byteCount, NULL, startingPacket, &packetCount, buffer);
		
		if(noErr != status || kCDSectorSizeCDDA != byteCount || AUDIO_FRAMES_PER_CDDA_SECTOR != packetCount)
			break;
		
		checksum += calculateAccurateRipChecksumForBlock(buffer, blockNumber++, totalBlocks, firstTrack, lastTrack);
		
		startingPacket += packetCount;
	}
	
	// Append silence, if required
	// Since the AccurateRip checksum for silence is zero, nothing need be done here
	if(sectorsOfSilenceToAppend)
		;

cleanup:
	status = AudioFileClose(file);
/*	if(noErr != status)
	 return 0;*/
	
return checksum;
}

// ========================================
// Generate the AccurateRip CRC for a sector of CDDA audio
// ========================================
uint32_t
calculateAccurateRipChecksumForBlock(const void *block, NSUInteger blockNumber, NSUInteger totalBlocks, BOOL firstTrack, BOOL lastTrack)
{
	NSCParameterAssert(NULL != block);

	if(firstTrack && 4 > blockNumber)
		return 0;
	else if(lastTrack && 6 > (totalBlocks - blockNumber))
		return 0;
	else if(firstTrack && 4 == blockNumber) {
		const uint32_t *buffer = (const uint32_t *)block;
		uint32_t sample = OSSwapHostToLittleInt32(buffer[AUDIO_FRAMES_PER_CDDA_SECTOR - 1]);
		return AUDIO_FRAMES_PER_CDDA_SECTOR * (4 + 1) * sample;
	}
	else {
		const uint32_t *buffer = (const uint32_t *)block;
		uint32_t checksum = 0;
		NSUInteger blockOffset = AUDIO_FRAMES_PER_CDDA_SECTOR * blockNumber;
		
		NSUInteger i;
		for(i = 0; i < AUDIO_FRAMES_PER_CDDA_SECTOR; ++i)
			checksum += OSSwapHostToLittleInt32(*buffer++) * ++blockOffset;

		return checksum;
	}
}

