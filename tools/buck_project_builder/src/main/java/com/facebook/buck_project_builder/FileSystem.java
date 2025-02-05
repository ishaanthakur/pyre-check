// Copyright 2004-present Facebook. All Rights Reserved.

package com.facebook.buck_project_builder;

import com.google.common.collect.ImmutableSet;
import org.apache.commons.io.IOUtils;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.Map;
import java.util.logging.Logger;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public final class FileSystem {

  private FileSystem() {}

  /**
   * @return a mapping from absolute source path to absolute output path as specified by the sources
   *     object. Files are not guaranteed to exist.
   */
  public static Map<String, String> resolveSourceMapping(
      String sourceDirectory, String outputDirectory, Map<String, String> sources) {
    Map<String, String> result = new HashMap<>();
    for (Map.Entry<String, String> entry : sources.entrySet()) {
      String sourceFile = entry.getKey();
      String outputFile = entry.getValue();
      result.put(
          Paths.get(sourceDirectory, sourceFile).toString(),
          Paths.get(outputDirectory, outputFile).toString());
    }
    return result;
  }

  public static void addSymbolicLink(Path linkPath, Path actualPath) {
    if (!actualPath.toFile().exists()) {
      // We ignore requests to create symbolic link when actual path does not exist.
      return;
    }
    linkPath.getParent().toFile().mkdirs();
    try {
      Files.deleteIfExists(linkPath);
      Files.createSymbolicLink(linkPath, actualPath);
    } catch (IOException exception) {
      Logger.getGlobal().severe("Cannot create symbolic link: " + exception.getMessage());
    }
  }

  /**
   * @return a set of files in the zip that are not unzipped because they can override existing
   *     files.
   */
  public static ImmutableSet<String> unzipRemoteFile(String remoteUrl, File outputDirectory)
      throws IOException {
    URL url = new URL(remoteUrl);
    File temporaryZipFile = Files.createTempFile("remote-", ".zip").toFile();
    try (InputStream remoteInputStream = url.openStream();
        FileOutputStream zipFileOutputStream = new FileOutputStream(temporaryZipFile)) {
      IOUtils.copy(remoteInputStream, zipFileOutputStream);
    }
    ImmutableSet.Builder<String> conflictingFileSetBuilder = ImmutableSet.builder();
    try (ZipFile zipFile = new ZipFile(temporaryZipFile)) {
      Enumeration<? extends ZipEntry> zipEntries = zipFile.entries();
      while (zipEntries.hasMoreElements()) {
        ZipEntry zipEntry = zipEntries.nextElement();
        if (!zipEntry.isDirectory()) {
          File outputFile = new File(outputDirectory, File.separator + zipEntry.getName());
          if (outputFile.exists()) {
            conflictingFileSetBuilder.add(zipEntry.getName());
            // Avoid overriding existing files, which might be symbolic links.
            continue;
          }
          outputFile.getParentFile().mkdirs();
          IOUtils.copy(zipFile.getInputStream(zipEntry), new FileOutputStream(outputFile));
        }
      }
    }
    temporaryZipFile.delete();
    return conflictingFileSetBuilder.build();
  }
}
